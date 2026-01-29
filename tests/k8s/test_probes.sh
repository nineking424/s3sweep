#!/usr/bin/env bash
# K8S-010 to K8S-013: Health probe tests for s3sweep

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helpers.sh"

NAMESPACE="s3sweep-test"
STATEFULSET="rclone-worker"

# K8S-010: Readiness probe on startup
test_readiness_on_startup() {
    test_start "K8S-010: Readiness probe after /tmp/healthy creation"

    # Restart pod to observe startup
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=0
    wait_for_ready_pods 0
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1

    local pod_name="${STATEFULSET}-0"

    # Wait for pod to be created
    log_info "Waiting for pod to be created..."
    for i in {1..30}; do
        if kubectl get pod "${pod_name}" -n "${NAMESPACE}" &>/dev/null; then
            break
        fi
        sleep 1
    done

    # Initially pod should NOT be ready
    log_info "Checking initial readiness status..."
    sleep 2
    local ready_status=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

    # Wait for health file to be created
    log_info "Waiting for /tmp/healthy to be created..."
    for i in {1..60}; do
        local health_exists=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- test -f /tmp/healthy && echo "true" || echo "false")
        if [ "$health_exists" = "true" ]; then
            log_info "Health file created"
            break
        fi
        sleep 1
    done

    # Now pod should become ready
    wait_for_ready_pods 1

    ready_status=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    assert_equals "True" "$ready_status" "Pod should be ready after /tmp/healthy exists"

    test_pass
}

# K8S-011: Liveness probe during work
test_liveness_during_work() {
    test_start "K8S-011: Liveness probe passes continuously during work"

    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    local pod_name="${STATEFULSET}-0"

    # Verify pod is running
    local phase=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')
    assert_equals "Running" "$phase" "Pod should be running"

    # Monitor liveness for 30 seconds
    log_info "Monitoring liveness probe for 30 seconds..."
    local restart_count_before=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].restartCount}')

    sleep 30

    local restart_count_after=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].restartCount}')
    assert_equals "$restart_count_before" "$restart_count_after" "Pod should not restart due to liveness failures"

    # Verify /tmp/healthy still exists
    local health_exists=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- test -f /tmp/healthy && echo "true" || echo "false")
    assert_equals "true" "$health_exists" "/tmp/healthy should exist during normal operation"

    test_pass
}

# K8S-012: Health removed on shutdown
test_health_removed_on_shutdown() {
    test_start "K8S-012: /tmp/healthy removed on graceful shutdown"

    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    local pod_name="${STATEFULSET}-0"

    # Verify health file exists
    local health_exists=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- test -f /tmp/healthy && echo "true" || echo "false")
    assert_equals "true" "$health_exists" "/tmp/healthy should exist before shutdown"

    # Send SIGTERM to simulate graceful shutdown
    log_info "Triggering graceful shutdown..."
    kubectl exec "${pod_name}" -n "${NAMESPACE}" -- sh -c 'kill -TERM 1' 2>/dev/null || true

    # Wait briefly for signal handling
    sleep 2

    # Check if health file was removed (pod may be terminating)
    local health_check=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- test -f /tmp/healthy && echo "exists" || echo "removed" 2>/dev/null || echo "pod-gone")

    if [ "$health_check" != "pod-gone" ]; then
        assert_equals "removed" "$health_check" "/tmp/healthy should be removed during graceful shutdown"
    else
        log_info "Pod already terminated (expected behavior)"
    fi

    # Restore pod
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=0
    wait_for_ready_pods 0
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    test_pass
}

# K8S-013: Stuck worker detection and restart
test_stuck_worker_detection() {
    test_start "K8S-013: Stuck worker detection via liveness probe"

    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    local pod_name="${STATEFULSET}-0"

    # Get initial restart count
    local restart_count_before=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].restartCount}')

    # Simulate stuck worker by removing health file
    log_info "Simulating stuck worker (removing /tmp/healthy)..."
    kubectl exec "${pod_name}" -n "${NAMESPACE}" -- rm -f /tmp/healthy

    # Wait for liveness probe to fail and trigger restart
    log_info "Waiting for liveness probe to detect failure..."

    local restarted=false
    for i in {1..60}; do
        local restart_count_after=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
        if [ "$restart_count_after" -gt "$restart_count_before" ]; then
            restarted=true
            log_info "Pod restarted after $(($i * 2)) seconds"
            break
        fi
        sleep 2
    done

    assert_true "$restarted" "Pod should restart when liveness probe fails"

    # Wait for pod to become ready again
    wait_for_ready_pods 1

    # Verify health file recreated
    local health_exists=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- test -f /tmp/healthy && echo "true" || echo "false")
    assert_equals "true" "$health_exists" "/tmp/healthy should be recreated after restart"

    test_pass
}

# Run all tests
run_all_tests() {
    test_suite_start "S3Sweep Health Probe Tests (K8S-010 to K8S-013)"

    test_readiness_on_startup
    test_liveness_during_work
    test_health_removed_on_shutdown
    test_stuck_worker_detection

    test_suite_end
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all_tests
fi
