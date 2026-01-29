#!/usr/bin/env bash
# K8S-001 to K8S-005: Scaling tests for s3sweep

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helpers.sh"

NAMESPACE="s3sweep-test"
STATEFULSET="rclone-worker"

# K8S-001: Scale up from 1 to 3 replicas
test_scale_up() {
    test_start "K8S-001: Scale up from 1 to 3 replicas"

    # Initial state: 1 replica
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    # Scale to 3
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=3
    wait_for_ready_pods 3

    # Verify all pods are running
    local pod_count=$(kubectl get pods -n "${NAMESPACE}" -l app=rclone-worker --field-selector=status.phase=Running --no-headers | wc -l)
    assert_equals 3 "$pod_count" "Expected 3 running pods"

    # Verify new workers have correct identities
    for i in 0 1 2; do
        local pod_name="${STATEFULSET}-${i}"
        local worker_id=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- env | grep "WORKER_ID=" | cut -d= -f2)
        assert_equals "$i" "$worker_id" "Pod ${pod_name} should have WORKER_ID=${i}"
    done

    test_pass
}

# K8S-002: Scale down from 3 to 1 replica with graceful shutdown
test_scale_down() {
    test_start "K8S-002: Scale down from 3 to 1 with graceful shutdown"

    # Ensure 3 replicas
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=3
    wait_for_ready_pods 3

    # Scale down to 1
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1

    # Wait for pods to terminate gracefully
    log_info "Waiting for pods to terminate..."
    sleep 5

    # Verify only 1 pod remains
    wait_for_ready_pods 1

    local pod_count=$(kubectl get pods -n "${NAMESPACE}" -l app=rclone-worker --field-selector=status.phase=Running --no-headers | wc -l)
    assert_equals 1 "$pod_count" "Expected 1 running pod after scale down"

    # Verify remaining pod is rclone-worker-0
    local pod_name=$(kubectl get pods -n "${NAMESPACE}" -l app=rclone-worker --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
    assert_equals "${STATEFULSET}-0" "$pod_name" "Remaining pod should be ${STATEFULSET}-0"

    test_pass
}

# K8S-003: Scale to zero and verify graceful shutdown
test_scale_to_zero() {
    test_start "K8S-003: Scale to zero with graceful shutdown"

    # Start with 1 replica
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    # Scale to zero
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=0

    # Wait for all pods to terminate
    log_info "Waiting for all pods to terminate..."
    for i in {1..30}; do
        local pod_count=$(kubectl get pods -n "${NAMESPACE}" -l app=rclone-worker --no-headers 2>/dev/null | wc -l)
        if [ "$pod_count" -eq 0 ]; then
            break
        fi
        sleep 2
    done

    # Verify no pods exist
    local pod_count=$(kubectl get pods -n "${NAMESPACE}" -l app=rclone-worker --no-headers 2>/dev/null | wc -l)
    assert_equals 0 "$pod_count" "Expected 0 pods after scale to zero"

    # Scale back up to verify recovery
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    test_pass
}

# K8S-004: Rapid scaling changes (stress test)
test_rapid_scaling() {
    test_start "K8S-004: Rapid scaling changes"

    # Start at 1
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    # Rapid scale: 1 -> 5 -> 2 -> 4 -> 1
    local scale_sequence=(5 2 4 1)

    for target in "${scale_sequence[@]}"; do
        log_info "Scaling to ${target} replicas..."
        kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas="${target}"
        sleep 3  # Brief wait between scale operations
    done

    # Wait for final stable state
    wait_for_ready_pods 1

    # Verify final state
    local pod_count=$(kubectl get pods -n "${NAMESPACE}" -l app=rclone-worker --field-selector=status.phase=Running --no-headers | wc -l)
    assert_equals 1 "$pod_count" "Expected 1 pod after rapid scaling"

    test_pass
}

# K8S-005: Worker identity verification
test_worker_identity() {
    test_start "K8S-005: Worker identity matches pod ordinal"

    # Scale to 3 for testing
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=3
    wait_for_ready_pods 3

    # Verify each pod has correct WORKER_ID and TOTAL_WORKERS
    for i in 0 1 2; do
        local pod_name="${STATEFULSET}-${i}"

        log_info "Checking identity for ${pod_name}..."

        # Get WORKER_ID
        local worker_id=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- sh -c 'echo $WORKER_ID' 2>/dev/null || echo "")
        assert_equals "$i" "$worker_id" "${pod_name} WORKER_ID should be ${i}"

        # Get TOTAL_WORKERS
        local total_workers=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- sh -c 'echo $TOTAL_WORKERS' 2>/dev/null || echo "")
        assert_equals "3" "$total_workers" "${pod_name} TOTAL_WORKERS should be 3"

        # Verify hostname matches pod name
        local hostname=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- hostname)
        assert_equals "${pod_name}" "$hostname" "Hostname should match pod name"
    done

    # Scale down and verify identity stability
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    local worker_id=$(kubectl exec "${STATEFULSET}-0" -n "${NAMESPACE}" -- sh -c 'echo $WORKER_ID' 2>/dev/null || echo "")
    assert_equals "0" "$worker_id" "Worker-0 should maintain WORKER_ID=0 after scale down"

    test_pass
}

# Run all tests
run_all_tests() {
    test_suite_start "S3Sweep Scaling Tests (K8S-001 to K8S-005)"

    test_scale_up
    test_scale_down
    test_scale_to_zero
    test_rapid_scaling
    test_worker_identity

    test_suite_end
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all_tests
fi
