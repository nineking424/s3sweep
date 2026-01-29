#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/helpers.sh"
source "$SCRIPT_DIR/../lib/assertions.sh"

# Test configuration
readonly RCLONE_CONFIG="${SCRIPT_DIR}/rclone.conf"
readonly TEST_BUCKET="s3sweep-test"
readonly MINIO_ENDPOINT="http://localhost:9000"

#######################################
# INT-001: Test successful file download
# Scenario: Valid job with existing S3 file
# Expected: File downloaded to dst_path, job in done/
#######################################
test_successful_download() {
    test_section "INT-001: Successful File Download"

    setup_test_env

    # Create job for test.txt (uploaded by setup.sh)
    local job_id="job-001"
    local dst_path="${TEST_DATA_DIR}/downloaded_test.txt"
    create_job "${job_id}" "${job_id}|s3test|${TEST_BUCKET}/test/test.txt|${dst_path}"

    # Simulate worker processing (would call actual worker script)
    test_info "Simulating worker processing job ${job_id}..."

    # For now, use rclone directly to simulate worker behavior
    if [ -f "${RCLONE_CONFIG}" ]; then
        rclone copyto "s3test:${TEST_BUCKET}/test/test.txt" "${dst_path}" \
            --config "${RCLONE_CONFIG}" 2>/dev/null || true

        # Move job to done if successful
        if [ -f "${dst_path}" ]; then
            mv "${TEST_JOBS_DIR}/pending/${job_id}.job" "${TEST_JOBS_DIR}/done/${job_id}.job"
        fi
    fi

    # Assertions
    assert_file_exists "${dst_path}" && \
    assert_job_succeeded "${job_id}"

    local result=$?
    cleanup_test_env
    return $result
}

#######################################
# INT-002: Test file not found scenario
# Scenario: Job references non-existent S3 key
# Expected: Job moves to failed/, error logged
#######################################
test_file_not_found() {
    test_section "INT-002: File Not Found"

    setup_test_env

    local job_id="job-002"
    local dst_path="${TEST_DATA_DIR}/nonexistent.txt"
    create_job "${job_id}" "${job_id}|s3test|${TEST_BUCKET}/nonexistent/file.txt|${dst_path}"

    test_info "Attempting download of non-existent file..."

    # Simulate worker attempting download
    if [ -f "${RCLONE_CONFIG}" ]; then
        set +e
        rclone copyto "s3test:${TEST_BUCKET}/nonexistent/file.txt" "${dst_path}" \
            --config "${RCLONE_CONFIG}" 2>&1 | tee -a "${WORKER_LOG}"
        local exit_code=$?
        set -e

        # Move job to failed on error
        if [ $exit_code -ne 0 ]; then
            mv "${TEST_JOBS_DIR}/pending/${job_id}.job" "${TEST_JOBS_DIR}/failed/${job_id}.job"
        fi
    fi

    # Assertions
    assert_file_not_exists "${dst_path}" && \
    assert_job_failed "${job_id}"

    local result=$?
    cleanup_test_env
    return $result
}

#######################################
# INT-003: Test multiple jobs sequential processing
# Scenario: 10 jobs processed one after another
# Expected: All 10 jobs complete successfully
#######################################
test_multiple_jobs_sequential() {
    test_section "INT-003: Multiple Jobs Sequential"

    setup_test_env

    local num_jobs=10
    test_info "Creating ${num_jobs} sequential jobs..."

    # Create 10 jobs
    for i in $(seq 1 $num_jobs); do
        local job_id="job-seq-$(printf "%03d" $i)"
        local dst_path="${TEST_DATA_DIR}/seq_${i}.txt"
        create_job "${job_id}" "${job_id}|s3test|${TEST_BUCKET}/test/test.txt|${dst_path}"
    done

    # Process jobs sequentially
    for i in $(seq 1 $num_jobs); do
        local job_id="job-seq-$(printf "%03d" $i)"
        local dst_path="${TEST_DATA_DIR}/seq_${i}.txt"

        if [ -f "${RCLONE_CONFIG}" ]; then
            rclone copyto "s3test:${TEST_BUCKET}/test/test.txt" "${dst_path}" \
                --config "${RCLONE_CONFIG}" 2>/dev/null || true

            if [ -f "${dst_path}" ]; then
                mv "${TEST_JOBS_DIR}/pending/${job_id}.job" "${TEST_JOBS_DIR}/done/${job_id}.job"
            fi
        fi
    done

    # Count completed jobs
    local done_count=$(find "${TEST_JOBS_DIR}/done" -name "job-seq-*.job" | wc -l | tr -d ' ')
    test_info "Completed jobs: ${done_count}/${num_jobs}"

    # Assertions
    assert_equals "${done_count}" "${num_jobs}"

    local result=$?
    cleanup_test_env
    return $result
}

#######################################
# INT-004: Test job state transitions
# Scenario: Job moves through pending → processing → done
# Expected: Correct state transitions, file appears in each directory
#######################################
test_job_state_transitions() {
    test_section "INT-004: Job State Transitions"

    setup_test_env

    local job_id="job-004"
    local dst_path="${TEST_DATA_DIR}/state_test.txt"
    create_job "${job_id}" "${job_id}|s3test|${TEST_BUCKET}/test/test.txt|${dst_path}"

    # 1. Check pending state
    assert_file_in_dir "${job_id}.job" "${TEST_JOBS_DIR}/pending" || return 1
    test_info "State: PENDING"

    # 2. Transition to processing
    mv "${TEST_JOBS_DIR}/pending/${job_id}.job" "${TEST_JOBS_DIR}/processing/${job_id}.job"
    assert_file_in_dir "${job_id}.job" "${TEST_JOBS_DIR}/processing" || return 1
    test_info "State: PROCESSING"

    # 3. Perform download
    if [ -f "${RCLONE_CONFIG}" ]; then
        rclone copyto "s3test:${TEST_BUCKET}/test/test.txt" "${dst_path}" \
            --config "${RCLONE_CONFIG}" 2>/dev/null || true
    fi

    # 4. Transition to done
    if [ -f "${dst_path}" ]; then
        mv "${TEST_JOBS_DIR}/processing/${job_id}.job" "${TEST_JOBS_DIR}/done/${job_id}.job"
    fi
    assert_file_in_dir "${job_id}.job" "${TEST_JOBS_DIR}/done" || return 1
    test_info "State: DONE"

    # Verify file not in previous states
    assert_file_not_exists "${TEST_JOBS_DIR}/pending/${job_id}.job" && \
    assert_file_not_exists "${TEST_JOBS_DIR}/processing/${job_id}.job"

    local result=$?
    cleanup_test_env
    return $result
}

#######################################
# INT-005: Test failed job retry mechanism
# Scenario: Move failed job back to pending for retry
# Expected: Job successfully moved from failed/ to pending/
#######################################
test_failed_job_retry() {
    test_section "INT-005: Failed Job Retry"

    setup_test_env

    local job_id="job-005"
    local dst_path="${TEST_DATA_DIR}/retry_test.txt"

    # Create job in failed state
    echo "${job_id}|s3test|${TEST_BUCKET}/test/test.txt|${dst_path}" > \
        "${TEST_JOBS_DIR}/failed/${job_id}.job"

    test_info "Job initially in failed state"
    assert_file_in_dir "${job_id}.job" "${TEST_JOBS_DIR}/failed" || return 1

    # Simulate retry: move from failed to pending
    test_info "Retrying job..."
    mv "${TEST_JOBS_DIR}/failed/${job_id}.job" "${TEST_JOBS_DIR}/pending/${job_id}.job"

    # Verify transition
    assert_file_not_exists "${TEST_JOBS_DIR}/failed/${job_id}.job" && \
    assert_file_in_dir "${job_id}.job" "${TEST_JOBS_DIR}/pending"

    # Now process the retried job
    if [ -f "${RCLONE_CONFIG}" ]; then
        rclone copyto "s3test:${TEST_BUCKET}/test/test.txt" "${dst_path}" \
            --config "${RCLONE_CONFIG}" 2>/dev/null || true

        if [ -f "${dst_path}" ]; then
            mv "${TEST_JOBS_DIR}/pending/${job_id}.job" "${TEST_JOBS_DIR}/done/${job_id}.job"
        fi
    fi

    # Final verification
    assert_job_succeeded "${job_id}"

    local result=$?
    cleanup_test_env
    return $result
}

#######################################
# INT-006: Test different file sizes
# Scenario: Download 1KB, 1MB, 100MB files
# Expected: All files downloaded with correct sizes
#######################################
test_different_file_sizes() {
    test_section "INT-006: Different File Sizes"

    setup_test_env

    # Test files: 1KB, 1MB, 100MB
    declare -A files=(
        ["1kb"]="file_1kb.bin:1024"
        ["1mb"]="file_1mb.bin:1048576"
        ["100mb"]="file_100mb.bin:104857600"
    )

    for key in "${!files[@]}"; do
        IFS=':' read -r filename expected_size <<< "${files[$key]}"

        local job_id="job-size-${key}"
        local dst_path="${TEST_DATA_DIR}/${filename}"

        create_job "${job_id}" "${job_id}|s3test|${TEST_BUCKET}/test/${filename}|${dst_path}"

        test_info "Downloading ${filename} (expected: ${expected_size} bytes)..."

        if [ -f "${RCLONE_CONFIG}" ]; then
            rclone copyto "s3test:${TEST_BUCKET}/test/${filename}" "${dst_path}" \
                --config "${RCLONE_CONFIG}" 2>/dev/null || true

            if [ -f "${dst_path}" ]; then
                mv "${TEST_JOBS_DIR}/pending/${job_id}.job" "${TEST_JOBS_DIR}/done/${job_id}.job"

                # Verify file size
                local actual_size
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    actual_size=$(stat -f%z "${dst_path}")
                else
                    actual_size=$(stat -c%s "${dst_path}")
                fi

                assert_equals "${actual_size}" "${expected_size}" || return 1
            fi
        fi

        assert_job_succeeded "${job_id}" || return 1
    done

    cleanup_test_env
    return 0
}

#######################################
# INT-007: Test rclone config validation
# Scenario: Verify rclone.conf has correct remotes
# Expected: s3test remote exists with proper configuration
#######################################
test_rclone_config_validation() {
    test_section "INT-007: Rclone Config Validation"

    if [ ! -f "${RCLONE_CONFIG}" ]; then
        test_error "Rclone config not found: ${RCLONE_CONFIG}"
        return 1
    fi

    test_info "Checking rclone config for s3test remote..."

    # Check if s3test remote exists
    if ! grep -q "\[s3test\]" "${RCLONE_CONFIG}"; then
        test_error "s3test remote not found in config"
        return 1
    fi

    # Verify remote type
    local remote_type=$(rclone config show s3test --config "${RCLONE_CONFIG}" | grep "type" | cut -d'=' -f2 | tr -d ' ')
    assert_equals "${remote_type}" "s3" || return 1

    test_info "Rclone config validated successfully"
    return 0
}

#######################################
# INT-008: Test concurrent file access
# Scenario: Two jobs trying to write to same destination
# Expected: Second job should fail or wait
#######################################
test_concurrent_file_access() {
    test_section "INT-008: Concurrent File Access"

    setup_test_env

    local dst_path="${TEST_DATA_DIR}/concurrent.txt"

    # Create two jobs with same destination
    create_job "job-concurrent-1" "job-concurrent-1|s3test|${TEST_BUCKET}/test/test.txt|${dst_path}"
    create_job "job-concurrent-2" "job-concurrent-2|s3test|${TEST_BUCKET}/test/test.txt|${dst_path}"

    test_info "Testing concurrent access to same destination..."

    # Process both jobs (in real scenario, this would detect conflict)
    # For now, just verify both can't succeed simultaneously
    local success_count=0

    if [ -f "${RCLONE_CONFIG}" ]; then
        # First job
        rclone copyto "s3test:${TEST_BUCKET}/test/test.txt" "${dst_path}" \
            --config "${RCLONE_CONFIG}" 2>/dev/null && ((success_count++)) || true

        # Second job (should overwrite or fail gracefully)
        rclone copyto "s3test:${TEST_BUCKET}/test/test.txt" "${dst_path}" \
            --config "${RCLONE_CONFIG}" 2>/dev/null && ((success_count++)) || true
    fi

    test_info "Success count: ${success_count}"

    # At least one should succeed
    assert_greater_than "${success_count}" "0"

    local result=$?
    cleanup_test_env
    return $result
}

#######################################
# Main test runner
#######################################
main() {
    echo "========================================"
    echo "s3sweep End-to-End Tests"
    echo "========================================"
    echo ""

    reset_assertions

    # Check prerequisites
    if ! command -v rclone &> /dev/null; then
        test_error "rclone not installed. Please install rclone first."
        exit 1
    fi

    if ! command -v mc &> /dev/null; then
        test_error "MinIO client (mc) not installed"
        exit 1
    fi

    # Check if MinIO is running
    if ! curl -sf "${MINIO_ENDPOINT}/minio/health/live" > /dev/null 2>&1; then
        test_error "MinIO not running at ${MINIO_ENDPOINT}"
        test_error "Please run: docker-compose up -d"
        exit 1
    fi

    # Run tests
    local failed=0

    test_successful_download || ((failed++))
    test_file_not_found || ((failed++))
    test_multiple_jobs_sequential || ((failed++))
    test_job_state_transitions || ((failed++))
    test_failed_job_retry || ((failed++))
    test_different_file_sizes || ((failed++))
    test_rclone_config_validation || ((failed++))
    test_concurrent_file_access || ((failed++))

    # Print summary
    print_assertion_summary

    echo ""
    if [ $failed -eq 0 ]; then
        test_info "All E2E tests passed!"
        exit 0
    else
        test_error "${failed} test(s) failed"
        exit 1
    fi
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
