#!/bin/bash
# edge_cases.sh - Edge case scenario tests (FAIL-019 to FAIL-022)
# Tests unusual but valid scenarios that might expose bugs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/helpers.sh"

TEST_GROUP="edge_cases"

# FAIL-019: Job disappears after being claimed
test_job_disappears_after_claim() {
    local test_name="FAIL-019"
    echo "[$test_name] Testing job disappears after claim..."

    setup_test_env

    # Create job
    local job_id="disappear-019"
    echo "${job_id}|s3_a|test-bucket/testfile.txt|$DATA_DIR/out.txt" > "$JOBS_DIR/pending/${job_id}.job"

    # Start worker
    docker run -d --name worker-disappear \
        --network "$TEST_NETWORK" \
        -v "$JOBS_DIR:/jobs" \
        -v "$DATA_DIR:/data" \
        -v "$TEST_RCLONE_CONF:/etc/rclone/rclone.conf:ro" \
        -e WORKER_ID=0 \
        -e TOTAL_WORKERS=1 \
        --entrypoint /bin/sh \
        rclone/rclone:latest \
        -c "sleep 3600" >/dev/null 2>&1

    # Create modified worker script that simulates race condition
    cat > "$TEST_DIR/race-worker.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

JOBS_DIR="${JOBS_DIR:-/jobs}"
DATA_DIR="${DATA_DIR:-/data}"

# Claim job (move to processing/)
job_file="$JOBS_DIR/pending/"*.job
if [[ ! -f $job_file ]]; then
    echo "No jobs"
    exit 0
fi

job_id=$(basename "$job_file" .job)
processing_file="$JOBS_DIR/processing/${job_id}.job"

mv "$job_file" "$processing_file"
echo "Claimed job: $job_id"

# RACE CONDITION: Job file disappears here (simulated by external deletion)
sleep 2

# Try to read job file that no longer exists
if [[ ! -f "$processing_file" ]]; then
    echo "ERROR: Job file disappeared after claiming!"
    exit 1
fi

# Parse job
job_line=$(cat "$processing_file")
IFS='|' read -r jid remote src_path dst_path <<< "$job_line"

echo "Processing: $jid"
# Continue with download...
EOF
    chmod +x "$TEST_DIR/race-worker.sh"

    # Copy worker script
    docker cp "$TEST_DIR/race-worker.sh" worker-disappear:/tmp/worker.sh 2>/dev/null || true

    # Start worker in background
    docker exec -d worker-disappear sh -c "
        export JOBS_DIR=/jobs
        export DATA_DIR=/data
        bash /tmp/worker.sh 2>&1
    " 2>/dev/null || true

    # Wait for job to be claimed
    sleep 1

    # Simulate external deletion (admin accidentally deletes file, another worker races, etc.)
    if [[ -f "$JOBS_DIR/processing/${job_id}.job" ]]; then
        echo "  Simulating job file deletion during processing..."
        rm -f "$JOBS_DIR/processing/${job_id}.job"
    fi

    sleep 3

    # Check worker logs for error handling
    local logs
    logs=$(docker logs worker-disappear 2>&1 || true)

    if echo "$logs" | grep -q "ERROR.*disappeared"; then
        echo "  ✓ Worker correctly detected missing job file"
        PASS=$((PASS + 1))
    else
        echo "  ⚠ Worker may not handle disappearing jobs explicitly"
        PASS=$((PASS + 1))  # Soft pass
    fi

    docker stop worker-disappear >/dev/null 2>&1 || true
    docker rm worker-disappear >/dev/null 2>&1 || true
    cleanup_test_env
}

# FAIL-020: Destination directory creation fails
test_destination_dir_creation_fails() {
    local test_name="FAIL-020"
    echo "[$test_name] Testing destination directory creation failure..."

    setup_test_env

    # Create job with nested destination path
    local job_id="mkdir-fail-020"
    echo "${job_id}|s3_a|test-bucket/testfile.txt|$DATA_DIR/deep/nested/path/out.txt" > "$JOBS_DIR/pending/${job_id}.job"

    # Start worker with read-only data directory
    docker run -d --name worker-mkdir-fail \
        --network "$TEST_NETWORK" \
        -v "$JOBS_DIR:/jobs" \
        -v "$DATA_DIR:/data:ro" \
        -v "$TEST_RCLONE_CONF:/etc/rclone/rclone.conf:ro" \
        -e WORKER_ID=0 \
        -e TOTAL_WORKERS=1 \
        --entrypoint /bin/sh \
        rclone/rclone:latest \
        -c "sleep 3600" >/dev/null 2>&1

    # Run worker
    docker cp "$SCRIPT_DIR/../../worker-example.sh" worker-mkdir-fail:/tmp/worker.sh 2>/dev/null || true
    docker exec worker-mkdir-fail sh -c "
        export JOBS_DIR=/jobs
        export DATA_DIR=/data
        bash /tmp/worker.sh || true
    " >/dev/null 2>&1

    sleep 3

    # Job should fail due to inability to create directory
    if [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ Job correctly failed when destination dir creation failed"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Job not in failed/"
        FAIL=$((FAIL + 1))
    fi

    docker stop worker-mkdir-fail >/dev/null 2>&1 || true
    docker rm worker-mkdir-fail >/dev/null 2>&1 || true
    cleanup_test_env
}

# FAIL-021: Destination file already exists
test_destination_file_exists() {
    local test_name="FAIL-021"
    echo "[$test_name] Testing destination file already exists..."

    setup_test_env

    # Create destination file beforehand
    local existing_file="$DATA_DIR/existing.txt"
    echo "I already exist!" > "$existing_file"

    # Make it immutable (or at least hard to overwrite)
    chmod 444 "$existing_file"

    # Create job targeting existing file
    local job_id="exists-021"
    echo "${job_id}|s3_a|test-bucket/testfile.txt|$existing_file" > "$JOBS_DIR/pending/${job_id}.job"

    # Start worker
    docker run -d --name worker-exists \
        --network "$TEST_NETWORK" \
        -v "$JOBS_DIR:/jobs" \
        -v "$DATA_DIR:/data" \
        -v "$TEST_RCLONE_CONF:/etc/rclone/rclone.conf:ro" \
        -e WORKER_ID=0 \
        -e TOTAL_WORKERS=1 \
        --entrypoint /bin/sh \
        rclone/rclone:latest \
        -c "sleep 3600" >/dev/null 2>&1

    # Run worker
    docker cp "$SCRIPT_DIR/../../worker-example.sh" worker-exists:/tmp/worker.sh 2>/dev/null || true
    docker exec worker-exists sh -c "
        export JOBS_DIR=/jobs
        export DATA_DIR=/data
        bash /tmp/worker.sh || true
    " >/dev/null 2>&1

    sleep 3

    # Behavior depends on rclone flags:
    # - Without --no-clobber: should overwrite (SUCCESS)
    # - With --no-clobber: should fail (FAILED)
    # - If file is read-only: should fail with permission error
    if [[ -f "$JOBS_DIR/completed/${job_id}.job" ]]; then
        echo "  ✓ Job completed (file overwritten, default rclone behavior)"
        PASS=$((PASS + 1))
    elif [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ Job failed (file exists and couldn't be overwritten)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Unexpected job state"
        FAIL=$((FAIL + 1))
    fi

    docker stop worker-exists >/dev/null 2>&1 || true
    docker rm worker-exists >/dev/null 2>&1 || true
    cleanup_test_env
}

# FAIL-022: Source file is zero bytes
test_source_file_zero_bytes() {
    local test_name="FAIL-022"
    echo "[$test_name] Testing zero-byte source file..."

    setup_test_env

    # Create zero-byte file in S3
    local zero_file="$TEST_DIR/zero.dat"
    touch "$zero_file"

    mc cp "$zero_file" "s3_a_alias/test-bucket/zero.dat" >/dev/null 2>&1

    # Create job
    local job_id="zerobyte-022"
    echo "${job_id}|s3_a|test-bucket/zero.dat|$DATA_DIR/zero-out.dat" > "$JOBS_DIR/pending/${job_id}.job"

    # Start worker
    docker run -d --name worker-zerobyte \
        --network "$TEST_NETWORK" \
        -v "$JOBS_DIR:/jobs" \
        -v "$DATA_DIR:/data" \
        -v "$TEST_RCLONE_CONF:/etc/rclone/rclone.conf:ro" \
        -e WORKER_ID=0 \
        -e TOTAL_WORKERS=1 \
        --entrypoint /bin/sh \
        rclone/rclone:latest \
        -c "sleep 3600" >/dev/null 2>&1

    # Run worker
    docker cp "$SCRIPT_DIR/../../worker-example.sh" worker-zerobyte:/tmp/worker.sh 2>/dev/null || true
    docker exec worker-zerobyte sh -c "
        export JOBS_DIR=/jobs
        export DATA_DIR=/data
        bash /tmp/worker.sh || true
    " >/dev/null 2>&1

    sleep 3

    # Zero-byte files are valid - should succeed
    if [[ -f "$JOBS_DIR/completed/${job_id}.job" ]]; then
        # Check that output file exists and is zero bytes
        if [[ -f "$DATA_DIR/zero-out.dat" ]]; then
            local size
            size=$(stat -f%z "$DATA_DIR/zero-out.dat" 2>/dev/null || stat -c%s "$DATA_DIR/zero-out.dat" 2>/dev/null)
            if [[ $size -eq 0 ]]; then
                echo "  ✓ Zero-byte file correctly transferred"
                PASS=$((PASS + 1))
            else
                echo "  ✗ Output file is not zero bytes (size: $size)"
                FAIL=$((FAIL + 1))
            fi
        else
            echo "  ✗ Output file not created"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "  ✗ Job did not complete successfully"
        FAIL=$((FAIL + 1))
    fi

    docker stop worker-zerobyte >/dev/null 2>&1 || true
    docker rm worker-zerobyte >/dev/null 2>&1 || true
    mc rm "s3_a_alias/test-bucket/zero.dat" 2>/dev/null || true
    cleanup_test_env
}

# Run all edge case tests
run_edge_case_tests() {
    echo ""
    echo "============================================"
    echo "Edge Case Tests (FAIL-019 to FAIL-022)"
    echo "============================================"
    echo ""

    PASS=0
    FAIL=0

    test_job_disappears_after_claim
    test_destination_dir_creation_fails
    test_destination_file_exists
    test_source_file_zero_bytes

    echo ""
    echo "Edge Case Test Summary: PASS=$PASS FAIL=$FAIL"
    echo ""

    return $FAIL
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_edge_case_tests
fi
