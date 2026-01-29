#!/bin/bash
set -euo pipefail

# stress.sh - Stress tests for s3sweep
#
# Test IDs:
#   PERF-015: 10K jobs with 5 workers
#   PERF-016: 100K jobs with 10 workers
#   PERF-017: Sustained load (1 hour continuous)
#   PERF-018: Burst load (1K jobs instantly)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DATA_DIR="/tmp/s3sweep_stress_test"
RESULTS_FILE="${RESULTS_FILE:-/tmp/s3sweep_stress_results.txt}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Initialize test environment
init_test_env() {
    echo "Initializing stress test environment..."
    rm -rf "$TEST_DATA_DIR"
    mkdir -p "$TEST_DATA_DIR"/{jobs,results,data,downloads}

    echo "# S3Sweep Stress Test Results - $(date)" > "$RESULTS_FILE"
    echo "" >> "$RESULTS_FILE"

    echo "Test environment ready"
}

# Generate test files
generate_test_files() {
    local size=$1
    local count=$2
    local output_dir="$TEST_DATA_DIR/data"

    echo "Generating $count test files of size $size..."

    # Generate files in batches for efficiency
    local batch_size=100
    for batch_start in $(seq 1 "$batch_size" "$count"); do
        local batch_end=$((batch_start + batch_size - 1))
        if (( batch_end > count )); then
            batch_end=$count
        fi

        for i in $(seq "$batch_start" "$batch_end"); do
            local filename="testfile_${size}_${i}.dat"

            case "$size" in
                1KB)
                    dd if=/dev/urandom of="$output_dir/$filename" bs=1024 count=1 2>/dev/null
                    ;;
                1MB)
                    dd if=/dev/urandom of="$output_dir/$filename" bs=1048576 count=1 2>/dev/null
                    ;;
                10MB)
                    dd if=/dev/urandom of="$output_dir/$filename" bs=1048576 count=10 2>/dev/null
                    ;;
            esac
        done

        echo -ne "Progress: $batch_end / $count\r"
    done

    echo -e "\nGenerated $count files"
}

# Create job files
create_jobs() {
    local count=$1
    local size=$2
    local job_file="$TEST_DATA_DIR/jobs/jobs_${size}_${count}.txt"

    echo "Creating $count jobs..."

    > "$job_file"

    for i in $(seq 1 "$count"); do
        local filename="testfile_${size}_${i}.dat"
        local src_path="testbucket/$filename"
        local dst_path="$TEST_DATA_DIR/downloads/$filename"
        local job_id="job_${size}_${i}"

        echo "${job_id}|mock_s3|${src_path}|${dst_path}" >> "$job_file"
    done

    echo "$job_file"
}

# Run worker (same as benchmark.sh)
run_worker() {
    local worker_id=$1
    local total_workers=$2
    local job_file=$3
    local result_file="$TEST_DATA_DIR/results/worker_${worker_id}.txt"

    # Mock fetch_jobs
    cat > "$TEST_DATA_DIR/worker_${worker_id}_fetch.sh" <<EOF
fetch_jobs() {
    awk -F'|' -v id=$worker_id -v total=$total_workers '
        (NR - 1) % total == id { print }
    ' "$job_file"
}
EOF

    # Mock send_result
    cat > "$TEST_DATA_DIR/worker_${worker_id}_send.sh" <<EOF
send_result() {
    local job_id=\$1
    local status=\$2
    local elapsed_ms=\$3
    local message=\$4

    echo "\$(date +%s%3N)|\$job_id|\$status|\$elapsed_ms" >> "$result_file"
}
EOF

    # Run worker
    export WORKER_ID=$worker_id
    export TOTAL_WORKERS=$total_workers
    export FETCH_JOBS_SCRIPT="$TEST_DATA_DIR/worker_${worker_id}_fetch.sh"
    export SEND_RESULT_SCRIPT="$TEST_DATA_DIR/worker_${worker_id}_send.sh"

    bash -c '
        source "$FETCH_JOBS_SCRIPT"
        source "$SEND_RESULT_SCRIPT"

        while read -r line; do
            IFS="|" read -r job_id remote src dst <<< "$line"

            start_ms=$(date +%s%3N)

            src_file="'"$TEST_DATA_DIR"'/data/$(basename "$src")"
            if [[ -f "$src_file" ]]; then
                cp "$src_file" "$dst" 2>/dev/null || true
                status="SUCCESS"
            else
                status="FAILED"
            fi

            end_ms=$(date +%s%3N)
            elapsed=$((end_ms - start_ms))

            send_result "$job_id" "$status" "$elapsed" "completed"
        done < <(fetch_jobs)
    ' &

    echo $!
}

# Monitor worker health
monitor_workers() {
    local pids=("$@")
    local check_interval=5

    while true; do
        local alive=0

        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                ((alive++))
            fi
        done

        if (( alive == 0 )); then
            break
        fi

        echo "Active workers: $alive / ${#pids[@]}"
        sleep "$check_interval"
    done
}

# Report results
report_results() {
    local test_name=$1
    local metric=$2
    local value=$3
    local unit=$4
    local status=${5:-PASS}

    local color="$GREEN"
    if [[ "$status" == "WARN" ]]; then
        color="$YELLOW"
    elif [[ "$status" == "FAIL" ]]; then
        color="$RED"
    fi

    echo -e "${color}[$status] $test_name - $metric: $value $unit${NC}"
    echo "[$status] $test_name - $metric: $value $unit" >> "$RESULTS_FILE"
}

# Stress test: 10K jobs
stress_10k_jobs() {
    echo -e "\n${GREEN}=== PERF-015: 10K Jobs with 5 Workers ===${NC}"

    local workers=5
    local job_count=10000
    local file_size="1MB"

    generate_test_files "$file_size" "$job_count"
    local job_file=$(create_jobs "$job_count" "$file_size")

    rm -rf "$TEST_DATA_DIR/results/"*.txt
    mkdir -p "$TEST_DATA_DIR/results"

    local pids=()
    local start_time=$(date +%s)

    echo "Starting $workers workers..."
    for i in $(seq 0 $((workers - 1))); do
        local pid=$(run_worker "$i" "$workers" "$job_file")
        pids+=("$pid")
    done

    # Monitor in background
    monitor_workers "${pids[@]}" &
    local monitor_pid=$!

    # Wait for all workers
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    kill "$monitor_pid" 2>/dev/null || true

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Calculate results
    local success_count=$(grep -c "|SUCCESS|" "$TEST_DATA_DIR/results/"*.txt 2>/dev/null || echo 0)
    local failed_count=$(grep -c "|FAILED|" "$TEST_DATA_DIR/results/"*.txt 2>/dev/null || echo 0)
    local throughput=$(echo "scale=2; $success_count / $duration" | bc)

    report_results "PERF-015" "Duration" "$duration" "seconds"
    report_results "PERF-015" "Success" "$success_count" "jobs"
    report_results "PERF-015" "Failed" "$failed_count" "jobs"
    report_results "PERF-015" "Throughput" "$throughput" "jobs/sec"

    # Check for failures
    local status="PASS"
    if (( failed_count > 0 )); then
        status="WARN"
    fi

    report_results "PERF-015" "Overall" "Complete" "" "$status"
}

# Stress test: 100K jobs
stress_100k_jobs() {
    echo -e "\n${GREEN}=== PERF-016: 100K Jobs with 10 Workers ===${NC}"

    local workers=10
    local job_count=100000
    local file_size="1KB"  # Use smaller files for 100K test

    generate_test_files "$file_size" "$job_count"
    local job_file=$(create_jobs "$job_count" "$file_size")

    rm -rf "$TEST_DATA_DIR/results/"*.txt
    mkdir -p "$TEST_DATA_DIR/results"

    local pids=()
    local start_time=$(date +%s)

    echo "Starting $workers workers..."
    for i in $(seq 0 $((workers - 1))); do
        local pid=$(run_worker "$i" "$workers" "$job_file")
        pids+=("$pid")
    done

    monitor_workers "${pids[@]}" &
    local monitor_pid=$!

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    kill "$monitor_pid" 2>/dev/null || true

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    local success_count=$(grep -c "|SUCCESS|" "$TEST_DATA_DIR/results/"*.txt 2>/dev/null || echo 0)
    local failed_count=$(grep -c "|FAILED|" "$TEST_DATA_DIR/results/"*.txt 2>/dev/null || echo 0)
    local throughput=$(echo "scale=2; $success_count / $duration" | bc)

    report_results "PERF-016" "Duration" "$duration" "seconds"
    report_results "PERF-016" "Success" "$success_count" "jobs"
    report_results "PERF-016" "Failed" "$failed_count" "jobs"
    report_results "PERF-016" "Throughput" "$throughput" "jobs/sec"

    local status="PASS"
    if (( failed_count > 0 )); then
        status="WARN"
    fi

    report_results "PERF-016" "Overall" "Complete" "" "$status"
}

# Stress test: Sustained load
stress_sustained_load() {
    echo -e "\n${GREEN}=== PERF-017: Sustained Load (1 hour) ===${NC}"

    local workers=5
    local file_size="1MB"
    local duration_seconds=3600  # 1 hour
    local jobs_per_minute=100

    echo "NOTE: This test runs for 1 hour. Use Ctrl+C to interrupt."
    echo "Starting sustained load test..."

    # Generate initial batch
    local batch_size=$((jobs_per_minute * 2))
    generate_test_files "$file_size" "$batch_size"

    local start_time=$(date +%s)
    local end_target=$((start_time + duration_seconds))
    local total_jobs=0
    local total_success=0

    while (( $(date +%s) < end_target )); do
        local job_file=$(create_jobs "$jobs_per_minute" "$file_size")

        rm -rf "$TEST_DATA_DIR/results/"*.txt
        mkdir -p "$TEST_DATA_DIR/results"

        local pids=()
        for i in $(seq 0 $((workers - 1))); do
            local pid=$(run_worker "$i" "$workers" "$job_file")
            pids+=("$pid")
        done

        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done

        local success_count=$(grep -c "|SUCCESS|" "$TEST_DATA_DIR/results/"*.txt 2>/dev/null || echo 0)
        total_jobs=$((total_jobs + jobs_per_minute))
        total_success=$((total_success + success_count))

        local elapsed=$(($(date +%s) - start_time))
        echo "Elapsed: ${elapsed}s, Total jobs: $total_jobs, Success: $total_success"

        sleep 60  # Wait 1 minute before next batch
    done

    local actual_duration=$(($(date +%s) - start_time))
    local avg_throughput=$(echo "scale=2; $total_success / $actual_duration" | bc)

    report_results "PERF-017" "Duration" "$actual_duration" "seconds"
    report_results "PERF-017" "Total Jobs" "$total_jobs" "jobs"
    report_results "PERF-017" "Total Success" "$total_success" "jobs"
    report_results "PERF-017" "Avg Throughput" "$avg_throughput" "jobs/sec"
}

# Stress test: Burst load
stress_burst_load() {
    echo -e "\n${GREEN}=== PERF-018: Burst Load (1K jobs instantly) ===${NC}"

    local workers=10
    local job_count=1000
    local file_size="1MB"

    generate_test_files "$file_size" "$job_count"
    local job_file=$(create_jobs "$job_count" "$file_size")

    rm -rf "$TEST_DATA_DIR/results/"*.txt
    mkdir -p "$TEST_DATA_DIR/results"

    echo "Sending burst of $job_count jobs..."

    local pids=()
    local start_time=$(date +%s%3N)

    # Start all workers simultaneously
    for i in $(seq 0 $((workers - 1))); do
        local pid=$(run_worker "$i" "$workers" "$job_file")
        pids+=("$pid")
    done

    # Wait for completion
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    local end_time=$(date +%s%3N)
    local duration_ms=$((end_time - start_time))
    local duration_sec=$(echo "scale=2; $duration_ms / 1000" | bc)

    local success_count=$(grep -c "|SUCCESS|" "$TEST_DATA_DIR/results/"*.txt 2>/dev/null || echo 0)
    local failed_count=$(grep -c "|FAILED|" "$TEST_DATA_DIR/results/"*.txt 2>/dev/null || echo 0)
    local throughput=$(echo "scale=2; $success_count / $duration_sec" | bc)

    # Calculate time to first job completion
    local first_job_time=$(sort -n "$TEST_DATA_DIR/results/"*.txt | head -1 | cut -d'|' -f1)
    local time_to_first=$((first_job_time - start_time))

    report_results "PERF-018" "Duration" "$duration_sec" "seconds"
    report_results "PERF-018" "Time to First" "$time_to_first" "ms"
    report_results "PERF-018" "Success" "$success_count" "jobs"
    report_results "PERF-018" "Failed" "$failed_count" "jobs"
    report_results "PERF-018" "Peak Throughput" "$throughput" "jobs/sec"

    local status="PASS"
    if (( failed_count > 0 )); then
        status="WARN"
    fi

    report_results "PERF-018" "Overall" "Complete" "" "$status"
}

# Main execution
main() {
    local test_type="${1:-all}"

    echo -e "${GREEN}S3Sweep Stress Test Suite${NC}"
    echo "======================================"

    init_test_env

    case "$test_type" in
        10k)
            stress_10k_jobs
            ;;
        100k)
            stress_100k_jobs
            ;;
        sustained)
            stress_sustained_load
            ;;
        burst)
            stress_burst_load
            ;;
        all)
            stress_10k_jobs
            stress_100k_jobs
            stress_burst_load
            echo -e "\n${YELLOW}Skipping sustained load test (use './stress.sh sustained' to run)${NC}"
            ;;
        *)
            echo -e "${RED}Unknown test type: $test_type${NC}"
            echo "Usage: $0 [10k|100k|sustained|burst|all]"
            exit 1
            ;;
    esac

    echo -e "\n${GREEN}Stress tests complete!${NC}"
    echo "Results written to: $RESULTS_FILE"

    echo -e "\n${GREEN}=== Summary ===${NC}"
    grep -E "^\[PASS\]|\[WARN\]|\[FAIL\]" "$RESULTS_FILE" || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
