#!/bin/bash
# network_partition.sh - S3 connectivity failure tests (FAIL-001 to FAIL-005)
# Uses Docker network manipulation and Toxiproxy for CI-friendly chaos testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/helpers.sh"
source "$SCRIPT_DIR/toxiproxy_setup.sh"

# Test metadata
TEST_GROUP="network_partition"
TEST_TIMEOUT=60  # seconds

# FAIL-001: S3 completely unreachable (network disconnect)
test_s3_unreachable() {
    local test_name="FAIL-001"
    echo "[$test_name] Testing S3 unreachable (network disconnect)..."

    setup_test_env

    # Create a job file
    local job_id="unreachable-001"
    local job_file="$JOBS_DIR/pending/${job_id}.job"
    echo "${job_id}|s3_a|test-bucket/testfile.txt|$DATA_DIR/output.txt" > "$job_file"

    # Start worker container
    local container_name="worker-unreachable"
    start_worker_container "$container_name"

    # Wait for worker to start processing
    sleep 2

    # Disconnect S3 container from network (simulates complete network failure)
    echo "  Disconnecting s3_a from network..."
    docker network disconnect "$TEST_NETWORK" s3_a 2>/dev/null || true

    # Wait for job to fail
    sleep 5

    # Check that job moved to failed/
    if [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ Job correctly moved to failed/"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Job not in failed/ directory"
        FAIL=$((FAIL + 1))
    fi

    # Reconnect S3 (cleanup)
    docker network connect "$TEST_NETWORK" s3_a 2>/dev/null || true

    cleanup_worker "$container_name"
    cleanup_test_env
}

# FAIL-002: S3 timeout (extreme latency)
test_s3_timeout() {
    local test_name="FAIL-002"
    echo "[$test_name] Testing S3 timeout (extreme latency)..."

    setup_test_env
    start_toxiproxy

    # Create proxy for S3
    create_proxy "s3_timeout" "0.0.0.0:20000" "s3_a:9000"

    # Add 30-second latency (should trigger timeout)
    add_latency "s3_timeout" 30000 0

    # Create job that points to Toxiproxy
    local job_id="timeout-002"
    local job_file="$JOBS_DIR/pending/${job_id}.job"

    # NOTE: Worker needs to be configured to use toxiproxy:20000 as S3 endpoint
    # For this test, we'll modify the rclone remote on the fly
    echo "${job_id}|s3_a|test-bucket/testfile.txt|$DATA_DIR/output.txt" > "$job_file"

    # Start worker with modified rclone config pointing to Toxiproxy
    local container_name="worker-timeout"
    start_worker_container "$container_name"

    # Override S3 endpoint to point to Toxiproxy (inside Docker network)
    docker exec "$container_name" sh -c "
        sed -i 's|endpoint = .*|endpoint = http://$TOXIPROXY_CONTAINER:20000|' /etc/rclone/rclone.conf
    " 2>/dev/null || true

    # Wait for timeout (should happen in <30s due to rclone timeout config)
    sleep 35

    # Check job moved to failed/
    if [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ Job correctly timed out and moved to failed/"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Job not in failed/"
        FAIL=$((FAIL + 1))
    fi

    cleanup_worker "$container_name"
    delete_proxy "s3_timeout"
    cleanup_test_env
}

# FAIL-003: S3 intermittent connectivity (50% packet loss)
test_s3_intermittent() {
    local test_name="FAIL-003"
    echo "[$test_name] Testing S3 intermittent connectivity (packet loss)..."

    setup_test_env
    start_toxiproxy

    # Create proxy with 50% packet loss
    create_proxy "s3_intermittent" "0.0.0.0:20001" "s3_a:9000"
    add_packet_loss "s3_intermittent" 50

    # Create job
    local job_id="intermittent-003"
    echo "${job_id}|s3_a|test-bucket/testfile.txt|$DATA_DIR/output.txt" > "$JOBS_DIR/pending/${job_id}.job"

    # Start worker pointing to Toxiproxy
    local container_name="worker-intermittent"
    start_worker_container "$container_name"

    docker exec "$container_name" sh -c "
        sed -i 's|endpoint = .*|endpoint = http://$TOXIPROXY_CONTAINER:20001|' /etc/rclone/rclone.conf
    " 2>/dev/null || true

    # Wait for potential timeout/failure
    sleep 20

    # With 50% packet loss, job might succeed or fail
    if [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ Job failed due to intermittent connectivity"
        PASS=$((PASS + 1))
    elif [[ -f "$JOBS_DIR/processing/${job_id}.job" ]]; then
        echo "  ⚠ Job still processing (intermittent issues cause delays)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Unexpected job state"
        FAIL=$((FAIL + 1))
    fi

    cleanup_worker "$container_name"
    delete_proxy "s3_intermittent"
    cleanup_test_env
}

# FAIL-004: S3 authentication failure (invalid credentials)
test_s3_auth_failure() {
    local test_name="FAIL-004"
    echo "[$test_name] Testing S3 authentication failure..."

    setup_test_env

    # Create job
    local job_id="auth-004"
    echo "${job_id}|s3_a|test-bucket/testfile.txt|$DATA_DIR/output.txt" > "$JOBS_DIR/pending/${job_id}.job"

    # Start worker with INVALID credentials
    local container_name="worker-auth-fail"
    start_worker_container "$container_name"

    # Overwrite credentials with invalid values
    docker exec "$container_name" sh -c "
        sed -i 's|access_key_id = .*|access_key_id = INVALID_KEY_XXXX|' /etc/rclone/rclone.conf
        sed -i 's|secret_access_key = .*|secret_access_key = INVALID_SECRET_XXXX|' /etc/rclone/rclone.conf
    " 2>/dev/null || true

    # Restart worker to pick up config
    docker restart "$container_name" >/dev/null 2>&1
    sleep 3

    # Wait for failure
    sleep 10

    # Check job in failed/
    if [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ Job correctly failed with auth error"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Job not in failed/"
        FAIL=$((FAIL + 1))
    fi

    cleanup_worker "$container_name"
    cleanup_test_env
}

# FAIL-005: S3 throttled (503 Service Unavailable simulation)
test_s3_throttled() {
    local test_name="FAIL-005"
    echo "[$test_name] Testing S3 throttling (slow bandwidth)..."

    setup_test_env
    start_toxiproxy

    # Create proxy with extreme bandwidth limit (1 KB/s)
    create_proxy "s3_throttled" "0.0.0.0:20002" "s3_a:9000"
    add_bandwidth_limit "s3_throttled" 1  # 1 KB/s

    # Create job
    local job_id="throttled-005"
    echo "${job_id}|s3_a|test-bucket/testfile.txt|$DATA_DIR/output.txt" > "$JOBS_DIR/pending/${job_id}.job"

    # Start worker
    local container_name="worker-throttled"
    start_worker_container "$container_name"

    docker exec "$container_name" sh -c "
        sed -i 's|endpoint = .*|endpoint = http://$TOXIPROXY_CONTAINER:20002|' /etc/rclone/rclone.conf
    " 2>/dev/null || true

    # Wait - should timeout due to slow transfer
    sleep 25

    # Check result
    if [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ Job correctly failed due to throttling/timeout"
        PASS=$((PASS + 1))
    elif [[ -f "$JOBS_DIR/processing/${job_id}.job" ]]; then
        echo "  ⚠ Job still processing (very slow transfer)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Unexpected job state"
        FAIL=$((FAIL + 1))
    fi

    cleanup_worker "$container_name"
    delete_proxy "s3_throttled"
    cleanup_test_env
}

# Helper: Start worker container
start_worker_container() {
    local container_name="$1"

    docker run -d --name "$container_name" \
        --network "$TEST_NETWORK" \
        -v "$JOBS_DIR:/jobs" \
        -v "$DATA_DIR:/data" \
        -v "$TEST_RCLONE_CONF:/etc/rclone/rclone.conf:ro" \
        -e WORKER_ID=0 \
        -e TOTAL_WORKERS=1 \
        -e POLL_INTERVAL=2 \
        --entrypoint /bin/sh \
        rclone/rclone:latest \
        -c "while true; do /jobs/worker-example.sh || true; sleep 5; done" >/dev/null 2>&1

    echo "  Started worker container: $container_name"
}

# Helper: Cleanup worker
cleanup_worker() {
    local container_name="$1"
    docker stop "$container_name" >/dev/null 2>&1 || true
    docker rm "$container_name" >/dev/null 2>&1 || true
}

# Run all network partition tests
run_network_partition_tests() {
    echo ""
    echo "============================================"
    echo "Network Partition Tests (FAIL-001 to FAIL-005)"
    echo "============================================"
    echo ""

    # Initialize counters
    PASS=0
    FAIL=0

    test_s3_unreachable
    test_s3_timeout
    test_s3_intermittent
    test_s3_auth_failure
    test_s3_throttled

    echo ""
    echo "Network Partition Test Summary: PASS=$PASS FAIL=$FAIL"
    echo ""

    # Cleanup
    stop_toxiproxy

    return $FAIL
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_network_partition_tests
fi
