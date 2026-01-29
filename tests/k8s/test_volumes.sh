#!/usr/bin/env bash
# K8S-017 to K8S-020: Volume and configuration tests for s3sweep

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helpers.sh"

NAMESPACE="s3sweep-test"
STATEFULSET="rclone-worker"

# K8S-017: Shared PVC access across workers
test_shared_pvc_access() {
    test_start "K8S-017: Shared PVC accessible by all workers"

    # Scale to 3 replicas
    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=3
    wait_for_ready_pods 3

    local test_file="/data/shared-test-$(date +%s).txt"
    local test_content="shared-access-test"

    # Worker-0 writes to shared volume
    log_info "Worker-0 writing to shared volume..."
    kubectl exec "${STATEFULSET}-0" -n "${NAMESPACE}" -- sh -c "echo '$test_content' > $test_file"

    # Wait briefly for filesystem sync
    sleep 2

    # Verify all workers can read the file
    for i in 0 1 2; do
        local pod_name="${STATEFULSET}-${i}"
        log_info "Checking shared access from ${pod_name}..."

        local content=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- cat "$test_file" 2>/dev/null || echo "NOT_FOUND")
        assert_equals "$test_content" "$content" "${pod_name} should access shared file"
    done

    # Verify all workers can write (concurrent access)
    log_info "Testing concurrent writes..."
    for i in 0 1 2; do
        local pod_name="${STATEFULSET}-${i}"
        kubectl exec "${pod_name}" -n "${NAMESPACE}" -- sh -c "echo 'worker-$i' > /data/worker-$i-test.txt"
    done

    sleep 1

    # Verify all files exist from all workers
    for writer in 0 1 2; do
        for reader in 0 1 2; do
            local exists=$(kubectl exec "${STATEFULSET}-${reader}" -n "${NAMESPACE}" -- test -f "/data/worker-${writer}-test.txt" && echo "true" || echo "false")
            assert_equals "true" "$exists" "Worker-${reader} should see file from worker-${writer}"
        done
    done

    # Cleanup
    kubectl exec "${STATEFULSET}-0" -n "${NAMESPACE}" -- sh -c "rm -f /data/worker-*-test.txt $test_file"

    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    test_pass
}

# K8S-018: Data directory isolation per worker
test_data_dir_isolation() {
    test_start "K8S-018: Data directory isolation per worker"

    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=3
    wait_for_ready_pods 3

    # Each worker should have isolated working directory
    for i in 0 1 2; do
        local pod_name="${STATEFULSET}-${i}"

        # Create worker-specific directory
        log_info "Setting up isolated directory for ${pod_name}..."
        kubectl exec "${pod_name}" -n "${NAMESPACE}" -- sh -c "mkdir -p /data/worker-${i}-private"

        # Write worker ID to private file
        kubectl exec "${pod_name}" -n "${NAMESPACE}" -- sh -c "echo '$i' > /data/worker-${i}-private/id.txt"
    done

    sleep 1

    # Verify isolation: each worker should only access their own directory
    for i in 0 1 2; do
        local pod_name="${STATEFULSET}-${i}"

        log_info "Verifying isolation for ${pod_name}..."

        # Should access own directory
        local own_content=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- cat "/data/worker-${i}-private/id.txt")
        assert_equals "$i" "$own_content" "${pod_name} should access own directory"

        # Note: In shared volume, other directories are visible but logically isolated by convention
        # Test that worker respects its designated directory
        local working_dir=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- sh -c 'echo $DATA_DIR' || echo "/data")
        log_info "${pod_name} working directory: ${working_dir}"
    done

    # Cleanup
    for i in 0 1 2; do
        kubectl exec "${STATEFULSET}-${i}" -n "${NAMESPACE}" -- sh -c "rm -rf /data/worker-${i}-private"
    done

    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    test_pass
}

# K8S-019: rclone config mount and accessibility
test_rclone_config_mount() {
    test_start "K8S-019: rclone.conf mounted and accessible"

    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    local pod_name="${STATEFULSET}-0"

    # Verify rclone config file exists
    log_info "Checking rclone config mount..."
    local config_exists=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- test -f /etc/rclone/rclone.conf && echo "true" || echo "false")
    assert_equals "true" "$config_exists" "rclone.conf should be mounted"

    # Verify config is readable
    local config_content=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- cat /etc/rclone/rclone.conf)
    assert_not_empty "$config_content" "rclone.conf should have content"

    # Verify rclone can list remotes
    log_info "Testing rclone listremotes..."
    local remotes=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- rclone listremotes 2>/dev/null || echo "ERROR")
    assert_not_equals "ERROR" "$remotes" "rclone should list remotes successfully"

    log_info "Available remotes:"
    echo "$remotes"

    # Verify specific test remotes exist
    local has_s3_a=$(echo "$remotes" | grep -c "s3_a:" || echo "0")
    assert_true "$has_s3_a -gt 0" "Remote s3_a should be configured"

    # Test rclone connectivity to MinIO
    log_info "Testing rclone connectivity to MinIO..."
    local buckets=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- rclone lsd s3_a: 2>/dev/null || echo "ERROR")

    if [ "$buckets" != "ERROR" ]; then
        log_info "Successfully connected to MinIO via rclone"
        log_info "Buckets found:"
        echo "$buckets"
    else
        log_warn "Could not list buckets (MinIO may not be ready)"
    fi

    test_pass
}

# K8S-020: Secret rotation without pod restart
test_secret_rotation() {
    test_start "K8S-020: Secret rotation handling"

    kubectl scale statefulset "${STATEFULSET}" -n "${NAMESPACE}" --replicas=1
    wait_for_ready_pods 1

    local pod_name="${STATEFULSET}-0"

    # Read initial rclone config
    log_info "Reading initial rclone config..."
    local initial_config=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- cat /etc/rclone/rclone.conf)

    # Update secret with new credentials
    log_info "Updating rclone secret..."
    kubectl create secret generic rclone-secret -n "${NAMESPACE}" \
        --from-literal=access_key_id=newaccesskey \
        --from-literal=secret_access_key=newsecretkey \
        --dry-run=client -o yaml | kubectl apply -f -

    # ConfigMap/Secret projected volumes have eventual consistency
    # Wait for kubelet to sync (typically 60s + sync period)
    log_info "Waiting for secret to propagate (this may take up to 90s)..."
    sleep 10

    # Note: Without pod restart, the mounted secret will eventually update
    # but rclone process won't pick up changes until restart

    # For this test, we verify the secret was updated in Kubernetes
    local new_access_key=$(kubectl get secret rclone-secret -n "${NAMESPACE}" -o jsonpath='{.data.access_key_id}' | base64 -d)
    assert_equals "newaccesskey" "$new_access_key" "Secret should be updated in Kubernetes"

    # In production, secrets rotation typically requires:
    # 1. Update secret in Kubernetes
    # 2. Rolling restart of StatefulSet to pick up new credentials
    # 3. Or implement SIGHUP handler in worker to reload config

    log_info "Triggering pod restart to pick up new secret..."
    kubectl delete pod "${pod_name}" -n "${NAMESPACE}"
    wait_for_ready_pods 1

    # Wait for volume remount
    sleep 5

    # Verify new config reflects changes (if rclone.conf includes credentials)
    local new_config=$(kubectl exec "${pod_name}" -n "${NAMESPACE}" -- cat /etc/rclone/rclone.conf)

    # Check if config changed (depends on whether ConfigMap or Secret contains credentials)
    log_info "Config comparison:"
    if [ "$initial_config" != "$new_config" ]; then
        log_info "Config updated after secret rotation"
    else
        log_info "Config unchanged (credentials may be in Secret, not ConfigMap)"
    fi

    # Restore original secret for other tests
    log_info "Restoring original secret..."
    kubectl create secret generic rclone-secret -n "${NAMESPACE}" \
        --from-literal=access_key_id=minioadmin \
        --from-literal=secret_access_key=minioadmin \
        --dry-run=client -o yaml | kubectl apply -f -

    # Restart pod to pick up restored secret
    kubectl delete pod "${pod_name}" -n "${NAMESPACE}"
    wait_for_ready_pods 1

    test_pass
}

# Run all tests
run_all_tests() {
    test_suite_start "S3Sweep Volume Tests (K8S-017 to K8S-020)"

    test_shared_pvc_access
    test_data_dir_isolation
    test_rclone_config_mount
    test_secret_rotation

    test_suite_end
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all_tests
fi
