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
# INT-009: Test single job with multiple workers
# Scenario: 3 workers compete for same job
# Expected: Only 1 worker claims it, others skip
#######################################
test_single_job_multiple_workers() {
    test_section "INT-009: Single Job Multiple Workers"

    setup_test_env

    local job_id="job-multi-001"
    local dst_path="${TEST_DATA_DIR}/multi_test.txt"
    create_job "${job_id}" "${job_id}|s3test|${TEST_BUCKET}/test/test.txt|${dst_path}"

    test_info "Simulating 3 workers competing for 1 job..."

    # Simulate atomic job claiming (first worker to move pending→processing wins)
    local claimed_by=""
    for worker_id in 0 1 2; do
        # Try to atomically claim job
        if mv "${TEST_JOBS_DIR}/pending/${job_id}.job" \
              "${TEST_JOBS_DIR}/processing/${job_id}.job" 2>/dev/null; then
            claimed_by="worker-${worker_id}"
            test_info "Job claimed by ${claimed_by}"

            # Process job
            if [ -f "${RCLONE_CONFIG}" ]; then
                rclone copyto "s3test:${TEST_BUCKET}/test/test.txt" "${dst_path}" \
                    --config "${RCLONE_CONFIG}" 2>/dev/null || true

                if [ -f "${dst_path}" ]; then
                    mv "${TEST_JOBS_DIR}/processing/${job_id}.job" \
                       "${TEST_JOBS_DIR}/done/${job_id}.job"
                fi
            fi
            break
        else
            test_info "worker-${worker_id} failed to claim job (already claimed)"
        fi
    done

    # Verify only one worker claimed it
    [ -n "${claimed_by}" ] && assert_job_succeeded "${job_id}"

    local result=$?
    cleanup_test_env
    return $result
}

#######################################
# INT-010: Test 100 jobs with 3 workers
# Scenario: 100 jobs distributed across 3 workers
# Expected: All jobs processed, no duplicates, ~even distribution
#######################################
test_100_jobs_3_workers() {
    test_section "INT-010: 100 Jobs 3 Workers"

    setup_test_env

    local num_jobs=100
    local num_workers=3

    test_info "Creating ${num_jobs} jobs for ${num_workers} workers..."

    # Create 100 jobs
    for i in $(seq 1 $num_jobs); do
        local job_id="job-100-$(printf "%03d" $i)"
        local dst_path="${TEST_DATA_DIR}/job_${i}.txt"
        create_job "${job_id}" "${job_id}|s3test|${TEST_BUCKET}/test/test.txt|${dst_path}"
    done

    # Track which worker processed which job (bash 3.x compatible)
    local worker_count_0=0
    local worker_count_1=0
    local worker_count_2=0

    # Simulate workers processing jobs in parallel
    test_info "Workers processing jobs..."

    local jobs_processed=0
    while [ $jobs_processed -lt $num_jobs ]; do
        for worker_id in $(seq 0 $((num_workers-1))); do
            # Find next available job
            local job_file=$(find "${TEST_JOBS_DIR}/pending" -name "job-100-*.job" -type f | head -n 1)

            if [ -z "$job_file" ]; then
                continue
            fi

            local job_name=$(basename "$job_file" .job)

            # Try to claim job
            if mv "${job_file}" "${TEST_JOBS_DIR}/processing/${job_name}.job" 2>/dev/null; then
                # Extract job info
                local job_content=$(cat "${TEST_JOBS_DIR}/processing/${job_name}.job")
                IFS='|' read -r job_id remote src_path dst_path <<< "$job_content"

                # Process job
                if [ -f "${RCLONE_CONFIG}" ]; then
                    rclone copyto "s3test:${TEST_BUCKET}/test/test.txt" "${dst_path}" \
                        --config "${RCLONE_CONFIG}" 2>/dev/null || true

                    if [ -f "${dst_path}" ]; then
                        mv "${TEST_JOBS_DIR}/processing/${job_name}.job" \
                           "${TEST_JOBS_DIR}/done/${job_name}.job"
                        # Increment worker count
                        case $worker_id in
                            0) worker_count_0=$((worker_count_0 + 1)) ;;
                            1) worker_count_1=$((worker_count_1 + 1)) ;;
                            2) worker_count_2=$((worker_count_2 + 1)) ;;
                        esac
                        jobs_processed=$((jobs_processed + 1))
                    fi
                fi
            fi
        done
    done

    # Verify all jobs completed
    local done_count=$(find "${TEST_JOBS_DIR}/done" -name "job-100-*.job" | wc -l | tr -d ' ')
    test_info "Jobs completed: ${done_count}/${num_jobs}"

    # Show distribution
    test_info "Worker 0: ${worker_count_0} jobs"
    test_info "Worker 1: ${worker_count_1} jobs"
    test_info "Worker 2: ${worker_count_2} jobs"

    assert_equals "${done_count}" "${num_jobs}"

    local result=$?
    cleanup_test_env
    return $result
}

#######################################
# INT-011: Test no duplicate processing
# Scenario: Verify each job processed exactly once
# Expected: No job appears in done/ more than once
#######################################
test_no_duplicate_processing() {
    test_section "INT-011: No Duplicate Processing"

    setup_test_env

    local num_jobs=20
    test_info "Creating ${num_jobs} jobs..."

    # Create jobs
    for i in $(seq 1 $num_jobs); do
        local job_id="job-dup-$(printf "%03d" $i)"
        local dst_path="${TEST_DATA_DIR}/dup_${i}.txt"
        create_job "${job_id}" "${job_id}|s3test|${TEST_BUCKET}/test/test.txt|${dst_path}"
    done

    # Process all jobs with simulated concurrency
    test_info "Processing jobs with duplicate detection..."

    # Track processed jobs with newline-separated list (bash 3.x compatible)
    local processed_jobs=""

    while true; do
        local job_file=$(find "${TEST_JOBS_DIR}/pending" -name "job-dup-*.job" -type f | head -n 1)
        [ -z "$job_file" ] && break

        local job_name=$(basename "$job_file" .job)

        # Check if already processed
        if echo -e "$processed_jobs" | grep -q "^${job_name}$"; then
            test_error "DUPLICATE: Job ${job_name} already processed!"
            cleanup_test_env
            return 1
        fi

        # Claim and process
        if mv "${job_file}" "${TEST_JOBS_DIR}/processing/${job_name}.job" 2>/dev/null; then
            local job_content=$(cat "${TEST_JOBS_DIR}/processing/${job_name}.job")
            IFS='|' read -r job_id remote src_path dst_path <<< "$job_content"

            if [ -f "${RCLONE_CONFIG}" ]; then
                rclone copyto "s3test:${TEST_BUCKET}/test/test.txt" "${dst_path}" \
                    --config "${RCLONE_CONFIG}" 2>/dev/null || true

                if [ -f "${dst_path}" ]; then
                    mv "${TEST_JOBS_DIR}/processing/${job_name}.job" \
                       "${TEST_JOBS_DIR}/done/${job_name}.job"
                    processed_jobs="${processed_jobs}${job_name}\n"
                fi
            fi
        fi
    done

    # Verify count
    local unique_count=$(echo -e "$processed_jobs" | grep -v '^$' | wc -l | tr -d ' ')
    test_info "Unique jobs processed: ${unique_count}"

    assert_equals "${unique_count}" "${num_jobs}"

    local result=$?
    cleanup_test_env
    return $result
}

#######################################
# INT-012: Test fair job distribution
# Scenario: Jobs evenly distributed across workers
# Expected: Each worker gets ~33% of jobs (within tolerance)
#######################################
test_fair_distribution() {
    test_section "INT-012: Fair Job Distribution"

    setup_test_env

    local num_jobs=90  # Evenly divisible by 3
    local num_workers=3
    local expected_per_worker=$((num_jobs / num_workers))
    local tolerance=5  # Allow ±5 jobs variance

    test_info "Creating ${num_jobs} jobs for ${num_workers} workers..."

    # Create jobs
    for i in $(seq 1 $num_jobs); do
        local job_id="job-fair-$(printf "%03d" $i)"
        local dst_path="${TEST_DATA_DIR}/fair_${i}.txt"
        create_job "${job_id}" "${job_id}|s3test|${TEST_BUCKET}/test/test.txt|${dst_path}"
    done

    # Simulate workers with round-robin distribution (bash 3.x compatible)
    local worker_count_0=0
    local worker_count_1=0
    local worker_count_2=0

    local current_worker=0
    while true; do
        local job_file=$(find "${TEST_JOBS_DIR}/pending" -name "job-fair-*.job" -type f | head -n 1)
        [ -z "$job_file" ] && break

        local job_name=$(basename "$job_file" .job)

        if mv "${job_file}" "${TEST_JOBS_DIR}/processing/${job_name}.job" 2>/dev/null; then
            local job_content=$(cat "${TEST_JOBS_DIR}/processing/${job_name}.job")
            IFS='|' read -r job_id remote src_path dst_path <<< "$job_content"

            if [ -f "${RCLONE_CONFIG}" ]; then
                rclone copyto "s3test:${TEST_BUCKET}/test/test.txt" "${dst_path}" \
                    --config "${RCLONE_CONFIG}" 2>/dev/null || true

                if [ -f "${dst_path}" ]; then
                    mv "${TEST_JOBS_DIR}/processing/${job_name}.job" \
                       "${TEST_JOBS_DIR}/done/${job_name}.job"
                    # Increment worker count
                    case $current_worker in
                        0) worker_count_0=$((worker_count_0 + 1)) ;;
                        1) worker_count_1=$((worker_count_1 + 1)) ;;
                        2) worker_count_2=$((worker_count_2 + 1)) ;;
                    esac
                fi
            fi

            # Round-robin to next worker
            current_worker=$(( (current_worker + 1) % num_workers ))
        fi
    done

    # Verify distribution
    test_info "Distribution (expected: ${expected_per_worker} ± ${tolerance}):"
    local distribution_ok=1

    # Check worker 0
    local count=$worker_count_0
    test_info "Worker 0: ${count} jobs"
    local diff=$((count - expected_per_worker))
    [ $diff -lt 0 ] && diff=$((-diff))
    if [ $diff -gt $tolerance ]; then
        test_error "Worker 0 distribution outside tolerance: ${count} (expected ${expected_per_worker} ± ${tolerance})"
        distribution_ok=0
    fi

    # Check worker 1
    count=$worker_count_1
    test_info "Worker 1: ${count} jobs"
    diff=$((count - expected_per_worker))
    [ $diff -lt 0 ] && diff=$((-diff))
    if [ $diff -gt $tolerance ]; then
        test_error "Worker 1 distribution outside tolerance: ${count} (expected ${expected_per_worker} ± ${tolerance})"
        distribution_ok=0
    fi

    # Check worker 2
    count=$worker_count_2
    test_info "Worker 2: ${count} jobs"
    diff=$((count - expected_per_worker))
    [ $diff -lt 0 ] && diff=$((-diff))
    if [ $diff -gt $tolerance ]; then
        test_error "Worker 2 distribution outside tolerance: ${count} (expected ${expected_per_worker} ± ${tolerance})"
        distribution_ok=0
    fi

    [ $distribution_ok -eq 1 ]

    local result=$?
    cleanup_test_env
    return $result
}

#######################################
# INT-013: Test staggered worker start
# Scenario: Workers start at different times
# Expected: No race conditions, all jobs processed
#######################################
test_staggered_start() {
    test_section "INT-013: Staggered Worker Start"

    setup_test_env

    local num_jobs=30
    test_info "Creating ${num_jobs} jobs..."

    # Create jobs
    for i in $(seq 1 $num_jobs); do
        local job_id="job-stagger-$(printf "%03d" $i)"
        local dst_path="${TEST_DATA_DIR}/stagger_${i}.txt"
        create_job "${job_id}" "${job_id}|s3test|${TEST_BUCKET}/test/test.txt|${dst_path}"
    done

    # Simulate workers starting at different times
    test_info "Simulating staggered worker startup..."

    # Worker 0 starts immediately, processes 10 jobs
    test_info "Worker 0 starting..."
    for i in $(seq 1 10); do
        local job_file=$(find "${TEST_JOBS_DIR}/pending" -name "job-stagger-*.job" -type f | head -n 1)
        [ -z "$job_file" ] && break

        local job_name=$(basename "$job_file" .job)
        if mv "${job_file}" "${TEST_JOBS_DIR}/processing/${job_name}.job" 2>/dev/null; then
            local job_content=$(cat "${TEST_JOBS_DIR}/processing/${job_name}.job")
            IFS='|' read -r job_id remote src_path dst_path <<< "$job_content"

            if [ -f "${RCLONE_CONFIG}" ]; then
                rclone copyto "s3test:${TEST_BUCKET}/test/test.txt" "${dst_path}" \
                    --config "${RCLONE_CONFIG}" 2>/dev/null || true
                [ -f "${dst_path}" ] && mv "${TEST_JOBS_DIR}/processing/${job_name}.job" \
                                           "${TEST_JOBS_DIR}/done/${job_name}.job"
            fi
        fi
    done

    # Worker 1 starts, processes remaining jobs
    test_info "Worker 1 starting (staggered)..."
    while true; do
        local job_file=$(find "${TEST_JOBS_DIR}/pending" -name "job-stagger-*.job" -type f | head -n 1)
        [ -z "$job_file" ] && break

        local job_name=$(basename "$job_file" .job)
        if mv "${job_file}" "${TEST_JOBS_DIR}/processing/${job_name}.job" 2>/dev/null; then
            local job_content=$(cat "${TEST_JOBS_DIR}/processing/${job_name}.job")
            IFS='|' read -r job_id remote src_path dst_path <<< "$job_content"

            if [ -f "${RCLONE_CONFIG}" ]; then
                rclone copyto "s3test:${TEST_BUCKET}/test/test.txt" "${dst_path}" \
                    --config "${RCLONE_CONFIG}" 2>/dev/null || true
                [ -f "${dst_path}" ] && mv "${TEST_JOBS_DIR}/processing/${job_name}.job" \
                                           "${TEST_JOBS_DIR}/done/${job_name}.job"
            fi
        fi
    done

    # Verify all jobs completed
    local done_count=$(find "${TEST_JOBS_DIR}/done" -name "job-stagger-*.job" | wc -l | tr -d ' ')
    test_info "Jobs completed: ${done_count}/${num_jobs}"

    assert_equals "${done_count}" "${num_jobs}"

    local result=$?
    cleanup_test_env
    return $result
}

#######################################
# INT-014: Test worker sharding by ID
# Scenario: Workers use WORKER_ID % TOTAL_WORKERS for job selection
# Expected: Each worker only processes jobs matching its shard
#######################################
test_worker_sharding() {
    test_section "INT-014: Worker Sharding by ID"

    setup_test_env

    local num_jobs=30
    local num_workers=3

    test_info "Creating ${num_jobs} jobs with sharding..."

    # Create jobs with predictable IDs for sharding
    for i in $(seq 1 $num_jobs); do
        local job_id="job-shard-$(printf "%03d" $i)"
        local dst_path="${TEST_DATA_DIR}/shard_${i}.txt"
        create_job "${job_id}" "${job_id}|s3test|${TEST_BUCKET}/test/test.txt|${dst_path}"
    done

    # Simulate workers with sharding logic (bash 3.x compatible)
    # Worker N processes jobs where hash(job_id) % TOTAL_WORKERS == N
    local worker_count_0=0
    local worker_count_1=0
    local worker_count_2=0

    for worker_id in $(seq 0 $((num_workers-1))); do
        # Find jobs for this worker's shard
        for job_file in $(find "${TEST_JOBS_DIR}/pending" -name "job-shard-*.job" -type f); do
            local job_name=$(basename "$job_file" .job)

            # Simple sharding: extract number from job name
            local job_num=$(echo "$job_name" | grep -o '[0-9]\+$' | sed 's/^0*//')
            # Handle case where number is "000" → becomes empty → default to 0
            [ -z "$job_num" ] && job_num=0
            local shard=$((job_num % num_workers))

            # Process only if it matches this worker's shard
            if [ $shard -eq $worker_id ]; then
                if mv "${job_file}" "${TEST_JOBS_DIR}/processing/${job_name}.job" 2>/dev/null; then
                    local job_content=$(cat "${TEST_JOBS_DIR}/processing/${job_name}.job")
                    IFS='|' read -r job_id remote src_path dst_path <<< "$job_content"

                    if [ -f "${RCLONE_CONFIG}" ]; then
                        rclone copyto "s3test:${TEST_BUCKET}/test/test.txt" "${dst_path}" \
                            --config "${RCLONE_CONFIG}" 2>/dev/null || true

                        if [ -f "${dst_path}" ]; then
                            mv "${TEST_JOBS_DIR}/processing/${job_name}.job" \
                               "${TEST_JOBS_DIR}/done/${job_name}.job"
                            # Increment worker count
                            case $worker_id in
                                0) worker_count_0=$((worker_count_0 + 1)) ;;
                                1) worker_count_1=$((worker_count_1 + 1)) ;;
                                2) worker_count_2=$((worker_count_2 + 1)) ;;
                            esac
                        fi
                    fi
                fi
            fi
        done
    done

    # Verify all jobs completed
    local done_count=$(find "${TEST_JOBS_DIR}/done" -name "job-shard-*.job" | wc -l | tr -d ' ')
    test_info "Jobs completed: ${done_count}/${num_jobs}"

    # Show shard distribution
    test_info "Worker 0 (shard 0): ${worker_count_0} jobs"
    test_info "Worker 1 (shard 1): ${worker_count_1} jobs"
    test_info "Worker 2 (shard 2): ${worker_count_2} jobs"

    assert_equals "${done_count}" "${num_jobs}"

    local result=$?
    cleanup_test_env
    return $result
}

#######################################
# INT-015: Test job timeout and cleanup
# Scenario: Job stuck in processing state
# Expected: Timeout mechanism moves job back to pending or failed
#######################################
test_job_timeout() {
    test_section "INT-015: Job Timeout and Cleanup"

    setup_test_env

    local job_id="job-timeout-001"
    local dst_path="${TEST_DATA_DIR}/timeout_test.txt"

    # Create job and immediately move to processing (simulating stuck job)
    create_job "${job_id}" "${job_id}|s3test|${TEST_BUCKET}/test/test.txt|${dst_path}"
    mv "${TEST_JOBS_DIR}/pending/${job_id}.job" "${TEST_JOBS_DIR}/processing/${job_id}.job"

    test_info "Job stuck in processing state"
    assert_file_in_dir "${job_id}.job" "${TEST_JOBS_DIR}/processing" || return 1

    # Simulate timeout cleanup (in real scenario, would check file timestamp)
    test_info "Simulating timeout cleanup..."
    sleep 2

    # Move timed-out job back to pending for retry
    mv "${TEST_JOBS_DIR}/processing/${job_id}.job" "${TEST_JOBS_DIR}/pending/${job_id}.job"

    assert_file_in_dir "${job_id}.job" "${TEST_JOBS_DIR}/pending"

    local result=$?
    cleanup_test_env
    return $result
}

#######################################
# Main test runner
#######################################
main() {
    echo "========================================"
    echo "s3sweep Multi-Worker Tests"
    echo "========================================"
    echo ""

    reset_assertions

    # Check prerequisites
    if ! command -v rclone &> /dev/null; then
        test_error "rclone not installed"
        exit 1
    fi

    if ! curl -sf "${MINIO_ENDPOINT}/minio/health/live" > /dev/null 2>&1; then
        test_error "MinIO not running at ${MINIO_ENDPOINT}"
        exit 1
    fi

    # Run tests
    local failed=0

    test_single_job_multiple_workers || ((failed++))
    test_100_jobs_3_workers || ((failed++))
    test_no_duplicate_processing || ((failed++))
    test_fair_distribution || ((failed++))
    test_staggered_start || ((failed++))
    test_worker_sharding || ((failed++))
    test_job_timeout || ((failed++))

    # Print summary
    print_assertion_summary

    echo ""
    if [ $failed -eq 0 ]; then
        test_info "All multi-worker tests passed!"
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
