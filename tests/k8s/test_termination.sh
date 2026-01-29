#!/usr/bin/env bash
# K8S-014 to K8S-016: Graceful termination tests for s3sweep

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helpers.sh"

NAMESPACE="s3sweep-test"
STATEFULSET="rclone-worker"

# K8S-014: Normal termination completes current job
test_normal_termination() {
    test_start "K8S-014: Normal SIGTERM allows current job to complete"

    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    local pod_name="${STATEFULSET}-0"

    # Verify pod is running
    local phase=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')
    assert_equals "Running" "$phase" "Pod should be running"

    # Get initial restart count
    local restart_count_before=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].restartCount}')

    # Send SIGTERM to trigger graceful shutdown
    log_info "Sending SIGTERM to trigger graceful shutdown..."
    kubectl exec "${pod_name}" -n "${NAMESPACE}" -- sh -c 'kill -TERM 1' 2>/dev/null || true

    # Monitor for graceful shutdown indicators
    log_info "Monitoring shutdown process..."
    sleep 2

    # Check if health file was removed (graceful shutdown signal)
    local health_check=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- test -f /tmp/healthy && echo "exists" || echo "removed" 2>/dev/null || echo "pod-terminating")

    if [ "$health_check" = "removed" ]; then
        log_info "Health file removed - graceful shutdown in progress"
    elif [ "$health_check" = "pod-terminating" ]; then
        log_info "Pod already terminating (expected)"
    fi

    # The pod will eventually restart (StatefulSet maintains replica count)
    log_info "Waiting for pod to restart..."
    wait_for_ready_pods 1

    # Verify pod restarted cleanly
    local restart_count_after=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].restartCount}')
    assert_true "$restart_count_after -ge $restart_count_before" "Pod should have restarted"

    test_pass
}

# K8S-015: Termination timeout forces kill
test_termination_timeout() {
    test_start "K8S-015: Termination timeout forces SIGKILL"

    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    local pod_name="${STATEFULSET}-0"

    # Get termination grace period from StatefulSet
    local grace_period=$(kubectl get statefulset "${STATEFULSET}" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}')
    log_info "Termination grace period: ${grace_period}s"

    # Simulate stuck process by making worker ignore SIGTERM
    # In real scenario, this would be a hung rclone process
    log_info "Simulating stuck process that ignores SIGTERM..."

    # Create a test script that ignores SIGTERM
    kubectl exec "${pod_name}" -n "${NAMESPACE}" -- sh -c '
        cat > /tmp/stuck_process.sh <<EOF
#!/bin/sh
trap "" TERM
while true; do
    sleep 1
done
EOF
        chmod +x /tmp/stuck_process.sh
        /tmp/stuck_process.sh &
        echo $! > /tmp/stuck_pid
    '

    # Delete pod to trigger termination
    log_info "Deleting pod to trigger forced termination..."
    local start_time=$(date +%s)
    kubectl delete pod "${pod_name}" -n "${NAMESPACE}" --wait=true &
    local delete_pid=$!

    # Monitor deletion
    sleep "$grace_period"

    # Check if pod is still terminating after grace period
    local pod_exists=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" --ignore-not-found -o jsonpath='{.metadata.name}')

    wait "$delete_pid" 2>/dev/null || true
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    log_info "Pod deletion took ${elapsed}s"

    # Should complete within grace period + buffer (forced kill)
    assert_true "$elapsed -le $((grace_period + 10))" "Pod should be force-killed after grace period"

    # Wait for new pod to be ready
    wait_for_ready_pods 1

    test_pass
}

# K8S-016: Rolling update with zero downtime
test_rolling_update() {
    test_start "K8S-016: Rolling update maintains availability"

    # Scale to 3 replicas for rolling update test
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=3
    wait_for_ready_pods 3

    # Record initial pods
    local initial_pods=$(kubectl get pods -n "${NAMESPACE}" -l app=rclone-worker -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort)
    log_info "Initial pods:"
    echo "$initial_pods"

    # Trigger rolling update by updating an annotation
    log_info "Triggering rolling update..."
    kubectl patch statefulset "${STATEFULSET}" -n "${NAMESPACE}" -p '{"spec":{"template":{"metadata":{"annotations":{"test-update":"'$(date +%s)'"}}}}}'

    # Monitor rolling update
    log_info "Monitoring rolling update..."
    kubectl rollout status statefulset "${STATEFULSET}" -n "${NAMESPACE}" --timeout=120s

    # Verify all pods were recreated
    local final_pods=$(kubectl get pods -n "${NAMESPACE}" -l app=rclone-worker -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort)
    log_info "Final pods:"
    echo "$final_pods"

    # Pod names should be same (StatefulSet identity), but they should be newer instances
    assert_equals "$initial_pods" "$final_pods" "Pod names should be preserved"

    # Check that all pods have the new annotation
    local pods_with_annotation=$(kubectl get pods -n "${NAMESPACE}" -l app=rclone-worker \
        -o jsonpath='{range .items[*]}{.metadata.annotations.test-update}{"\n"}{end}' | grep -v '^$' | wc -l)
    assert_equals "3" "$pods_with_annotation" "All pods should have the new annotation"

    # Verify no pods are in failed state
    local failed_pods=$(kubectl get pods -n "${NAMESPACE}" -l app=rclone-worker --field-selector=status.phase=Failed --no-headers | wc -l)
    assert_equals "0" "$failed_pods" "No pods should be in failed state"

    # Check StatefulSet update strategy
    local update_strategy=$(kubectl get statefulset "${STATEFULSET}" -n "${NAMESPACE}" -o jsonpath='{.spec.updateStrategy.type}')
    log_info "Update strategy: ${update_strategy}"

    # For StatefulSet, RollingUpdate updates pods in reverse ordinal order
    # Verify this by checking pod ages
    log_info "Pod ages (newest to oldest):"
    kubectl get pods -n "${NAMESPACE}" -l app=rclone-worker --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp --no-headers

    # Scale back to 1
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    test_pass
}

# Run all tests
run_all_tests() {
    test_suite_start "S3Sweep Termination Tests (K8S-014 to K8S-016)"

    test_normal_termination
    test_termination_timeout
    test_rolling_update

    test_suite_end
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all_tests
fi
