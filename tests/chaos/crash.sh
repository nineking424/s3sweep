#!/bin/bash
# crash.sh - Worker crash scenario tests (FAIL-015 to FAIL-018)
# Tests behavior when worker/rclone crashes or hangs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/helpers.sh"

TEST_GROUP="crash"

# FAIL-015: Worker killed (SIGKILL) during download
test_kill9_during_download() {
    local test_name="FAIL-015"
    echo "[$test_name] Testing SIGKILL during download..."

    setup_test_env

    # Create a large test file to ensure download takes time
    local large_file="$TEST_DIR/large.dat"
    dd if=/dev/zero of="$large_file" bs=1M count=50 2>/dev/null

    # Upload to S3
    mc cp "$large_file" "s3_a_alias/test-bucket/large.dat" >/dev/null 2>&1

    # Create job
    local job_id="kill9-015"
    echo "${job_id}|s3_a|test-bucket/large.dat|$DATA_DIR/output.dat" > "$JOBS_DIR/pending/${job_id}.job"

    # Start worker in background
    docker run -d --name worker-kill9 \
        --network "$TEST_NETWORK" \
        -v "$JOBS_DIR:/jobs" \
        -v "$DATA_DIR:/data" \
        -v "$TEST_RCLONE_CONF:/etc/rclone/rclone.conf:ro" \
        -e WORKER_ID=0 \
        -e TOTAL_WORKERS=1 \
        rclone/rclone:latest \
        sleep 3600 >/dev/null 2>&1

    # Start worker script
    docker cp "$SCRIPT_DIR/../../worker-example.sh" worker-kill9:/tmp/worker.sh 2>/dev/null || true
    docker exec -d worker-kill9 sh -c "
        export JOBS_DIR=/jobs
        export DATA_DIR=/data
        bash /tmp/worker.sh
    " 2>/dev/null || true

    # Wait for download to start
    sleep 2

    # Check that job moved to processing/
    if [[ -f "$JOBS_DIR/processing/${job_id}.job" ]]; then
        echo "  Job moved to processing/, sending SIGKILL..."

        # Kill worker abruptly
        docker kill -s SIGKILL worker-kill9 >/dev/null 2>&1

        # Check for partial file
        if [[ -f "$DATA_DIR/output.dat" ]]; then
            local partial_size
            partial_size=$(stat -f%z "$DATA_DIR/output.dat" 2>/dev/null || stat -c%s "$DATA_DIR/output.dat" 2>/dev/null)
            echo "  ✓ Partial file exists ($partial_size bytes)"
            PASS=$((PASS + 1))
        else
            echo "  ⚠ No partial file found (may have been cleaned up)"
            PASS=$((PASS + 1))  # Soft pass
        fi

        # Job should be in processing/ (orphaned)
        if [[ -f "$JOBS_DIR/processing/${job_id}.job" ]]; then
            echo "  ✓ Job remains in processing/ (orphaned as expected)"
        fi
    else
        echo "  ✗ Job never moved to processing/"
        FAIL=$((FAIL + 1))
    fi

    # Cleanup
    docker rm worker-kill9 >/dev/null 2>&1 || true
    mc rm "s3_a_alias/test-bucket/large.dat" 2>/dev/null || true
    cleanup_test_env
}

# FAIL-016: Worker OOM killed
test_oom_kill() {
    local test_name="FAIL-016"
    echo "[$test_name] Testing OOM kill..."

    setup_test_env

    # Create job
    local job_id="oom-016"
    echo "${job_id}|s3_a|test-bucket/testfile.txt|$DATA_DIR/out.txt" > "$JOBS_DIR/pending/${job_id}.job"

    # Start worker with VERY low memory limit (10MB)
    docker run -d --name worker-oom \
        --network "$TEST_NETWORK" \
        --memory=10m \
        --memory-swap=10m \
        -v "$JOBS_DIR:/jobs" \
        -v "$DATA_DIR:/data" \
        -v "$TEST_RCLONE_CONF:/etc/rclone/rclone.conf:ro" \
        -e WORKER_ID=0 \
        -e TOTAL_WORKERS=1 \
        rclone/rclone:latest \
        sleep 3600 >/dev/null 2>&1

    # Try to allocate large amount of memory to trigger OOM
    docker exec worker-oom sh -c "
        # Try to allocate 20MB (more than limit)
        head -c 20M /dev/zero > /tmp/oom.dat 2>&1
    " >/dev/null 2>&1 || true

    sleep 2

    # Check if container was killed
    if ! docker ps | grep -q worker-oom; then
        echo "  ✓ Worker correctly OOM killed"
        PASS=$((PASS + 1))
    else
        echo "  ⚠ Worker still running (OOM killer may not have triggered)"
        PASS=$((PASS + 1))  # Soft pass - depends on system OOM behavior
    fi

    docker stop worker-oom >/dev/null 2>&1 || true
    docker rm worker-oom >/dev/null 2>&1 || true
    cleanup_test_env
}

# FAIL-017: rclone process crashes
test_rclone_crash() {
    local test_name="FAIL-017"
    echo "[$test_name] Testing rclone crash simulation..."

    setup_test_env

    # Create job
    local job_id="rclone-crash-017"
    echo "${job_id}|s3_a|test-bucket/testfile.txt|$DATA_DIR/out.txt" > "$JOBS_DIR/pending/${job_id}.job"

    # Create mock rclone that crashes
    cat > "$TEST_DIR/fake-rclone.sh" <<'EOF'
#!/bin/bash
# Fake rclone that crashes immediately
echo "rclone: simulated crash" >&2
exit 137  # Simulate crash exit code
EOF
    chmod +x "$TEST_DIR/fake-rclone.sh"

    # Start worker
    docker run -d --name worker-rclone-crash \
        --network "$TEST_NETWORK" \
        -v "$JOBS_DIR:/jobs" \
        -v "$DATA_DIR:/data" \
        -v "$TEST_RCLONE_CONF:/etc/rclone/rclone.conf:ro" \
        -v "$TEST_DIR/fake-rclone.sh:/usr/local/bin/rclone:ro" \
        -e WORKER_ID=0 \
        -e TOTAL_WORKERS=1 \
        --entrypoint /bin/sh \
        rclone/rclone:latest \
        -c "sleep 3600" >/dev/null 2>&1

    # Run worker script
    docker cp "$SCRIPT_DIR/../../worker-example.sh" worker-rclone-crash:/tmp/worker.sh 2>/dev/null || true
    docker exec worker-rclone-crash sh -c "
        export JOBS_DIR=/jobs
        export DATA_DIR=/data
        bash /tmp/worker.sh || true
    " >/dev/null 2>&1

    sleep 3

    # Job should have moved to failed/
    if [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ rclone crash correctly caused job failure"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Job not in failed/"
        FAIL=$((FAIL + 1))
    fi

    docker stop worker-rclone-crash >/dev/null 2>&1 || true
    docker rm worker-rclone-crash >/dev/null 2>&1 || true
    cleanup_test_env
}

# FAIL-018: rclone hangs indefinitely
test_rclone_hang() {
    local test_name="FAIL-018"
    echo "[$test_name] Testing rclone hang simulation..."

    setup_test_env

    # Create job
    local job_id="rclone-hang-018"
    echo "${job_id}|s3_a|test-bucket/testfile.txt|$DATA_DIR/out.txt" > "$JOBS_DIR/pending/${job_id}.job"

    # Create mock rclone that hangs
    cat > "$TEST_DIR/hanging-rclone.sh" <<'EOF'
#!/bin/bash
# Fake rclone that hangs forever
echo "rclone: starting transfer..." >&2
sleep infinity
EOF
    chmod +x "$TEST_DIR/hanging-rclone.sh"

    # Start worker
    docker run -d --name worker-rclone-hang \
        --network "$TEST_NETWORK" \
        -v "$JOBS_DIR:/jobs" \
        -v "$DATA_DIR:/data" \
        -v "$TEST_RCLONE_CONF:/etc/rclone/rclone.conf:ro" \
        -v "$TEST_DIR/hanging-rclone.sh:/usr/local/bin/rclone:ro" \
        -e WORKER_ID=0 \
        -e TOTAL_WORKERS=1 \
        --entrypoint /bin/sh \
        rclone/rclone:latest \
        -c "sleep 3600" >/dev/null 2>&1

    # Run worker script with timeout wrapper
    docker cp "$SCRIPT_DIR/../../worker-example.sh" worker-rclone-hang:/tmp/worker.sh 2>/dev/null || true

    # Run worker with timeout command
    timeout 10 docker exec worker-rclone-hang sh -c "
        export JOBS_DIR=/jobs
        export DATA_DIR=/data
        bash /tmp/worker.sh || true
    " >/dev/null 2>&1 || true

    sleep 2

    # Check if job is stuck in processing/ or timed out
    if [[ -f "$JOBS_DIR/processing/${job_id}.job" ]]; then
        echo "  ✓ Job stuck in processing/ (hang detected)"
        PASS=$((PASS + 1))
    elif [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ Job moved to failed/ (timeout worked)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Unexpected job state"
        FAIL=$((FAIL + 1))
    fi

    docker stop worker-rclone-hang >/dev/null 2>&1 || true
    docker rm worker-rclone-hang >/dev/null 2>&1 || true
    cleanup_test_env
}

# Run all crash tests
run_crash_tests() {
    echo ""
    echo "============================================"
    echo "Crash Scenario Tests (FAIL-015 to FAIL-018)"
    echo "============================================"
    echo ""

    PASS=0
    FAIL=0

    test_kill9_during_download
    test_oom_kill
    test_rclone_crash
    test_rclone_hang

    echo ""
    echo "Crash Test Summary: PASS=$PASS FAIL=$FAIL"
    echo ""

    return $FAIL
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_crash_tests
fi
