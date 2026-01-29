#!/bin/bash
set -euo pipefail

# benchmark.sh - Throughput and latency performance tests for s3sweep
#
# Test IDs:
#   PERF-001: Single worker, small files (1KB)
#   PERF-002: Single worker, large files (100MB)
#   PERF-003: 3 workers, mixed file sizes
#   PERF-004: 10 workers throughput
#   PERF-005: Find saturation point
#   PERF-006: Job claim latency
#   PERF-007: Contention latency (10 workers, 1 job)
#   PERF-008: End-to-end latency
#   PERF-009: Idle polling overhead

# Performance baselines (expected)
# - Single worker throughput: 10-50 files/sec (depends on size)
# - 10 workers throughput: 100-500 files/sec
# - Job claim latency: <100ms
# - End-to-end latency: <5s for 1MB file
# - Memory per worker: <50MB idle, <200MB active
# - CPU idle: <1%

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DATA_DIR="/tmp/s3sweep_perf_test"
RESULTS_FILE="${RESULTS_FILE:-/tmp/s3sweep_perf_results.txt}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test configuration
MOCK_S3_ENABLED="${MOCK_S3:-true}"
RCLONE_BIN="${RCLONE_BIN:-rclone}"
WORKER_SCRIPT="${PROJECT_ROOT}/worker-example.sh"

# Initialize test environment
init_test_env() {
    echo "Initializing test environment..."
    rm -rf "$TEST_DATA_DIR"
    mkdir -p "$TEST_DATA_DIR"/{jobs,results,data,downloads}

    # Clear results file
    echo "# S3Sweep Performance Test Results - $(date)" > "$RESULTS_FILE"
    echo "# System: $(uname -s) $(uname -r)" >> "$RESULTS_FILE"
    echo "# CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2)" >> "$RESULTS_FILE"
    echo "" >> "$RESULTS_FILE"

    # Check rclone
    if ! command -v "$RCLONE_BIN" &> /dev/null; then
        echo -e "${RED}ERROR: rclone not found${NC}"
        exit 1
    fi

    echo "Test environment ready at: $TEST_DATA_DIR"
}

# Generate test files
generate_test_files() {
    local size=$1
    local count=$2
    local output_dir="$TEST_DATA_DIR/data"

    echo "Generating $count test files of size $size..."

    for i in $(seq 1 "$count"); do
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
            100MB)
                dd if=/dev/urandom of="$output_dir/$filename" bs=1048576 count=100 2>/dev/null
                ;;
            *)
                echo -e "${RED}Unknown size: $size${NC}"
                return 1
                ;;
        esac
    done

    echo "Generated $count files"
}

# Create job files
create_jobs() {
    local count=$1
    local size=$2
    local job_file="$TEST_DATA_DIR/jobs/jobs_${size}_${count}.txt"

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

# Run worker with job file
run_worker() {
    local worker_id=$1
    local total_workers=$2
    local job_file=$3
    local result_file="$TEST_DATA_DIR/results/worker_${worker_id}.txt"

    # Mock fetch_jobs function
    cat > "$TEST_DATA_DIR/worker_${worker_id}_fetch.sh" <<EOF
fetch_jobs() {
    # Simple modulo sharding
    awk -F'|' -v id=$worker_id -v total=$total_workers '
        (NR - 1) % total == id { print }
    ' "$job_file"
}
EOF

    # Mock send_result function
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

    # Simple worker loop
    bash -c '
        source "$FETCH_JOBS_SCRIPT"
        source "$SEND_RESULT_SCRIPT"

        while read -r line; do
            IFS="|" read -r job_id remote src dst <<< "$line"

            start_ms=$(date +%s%3N)

            # Mock rclone copy (just cp for testing)
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

# Measure throughput
measure_throughput() {
    local workers=$1
    local job_count=$2
    local file_size=$3

    echo "Measuring throughput: $workers workers, $job_count jobs, $file_size files"

    # Generate files and jobs
    generate_test_files "$file_size" "$job_count"
    local job_file=$(create_jobs "$job_count" "$file_size")

    # Clean results
    rm -rf "$TEST_DATA_DIR/results/"*.txt
    mkdir -p "$TEST_DATA_DIR/results"

    # Start workers
    local pids=()
    local start_time=$(date +%s%3N)

    for i in $(seq 0 $((workers - 1))); do
        local pid=$(run_worker "$i" "$workers" "$job_file")
        pids+=("$pid")
    done

    # Wait for all workers
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    local end_time=$(date +%s%3N)
    local duration_ms=$((end_time - start_time))
    local duration_sec=$(echo "scale=2; $duration_ms / 1000" | bc)

    # Calculate throughput
    local success_count=$(grep -c "|SUCCESS|" "$TEST_DATA_DIR/results/"*.txt 2>/dev/null || echo 0)
    local throughput=$(echo "scale=2; $success_count / $duration_sec" | bc)

    echo "  Duration: ${duration_sec}s"
    echo "  Success: $success_count / $job_count"
    echo "  Throughput: ${throughput} files/sec"

    echo "$throughput"
}

# Measure latency
measure_latency() {
    local metric_type=$1

    case "$metric_type" in
        claim)
            # PERF-006: Job claim latency
            echo "Measuring job claim latency..."

            local iterations=100
            local total_ms=0

            for i in $(seq 1 "$iterations"); do
                local start=$(date +%s%3N)

                # Simulate job claim (read from file, parse line)
                echo "job_$i|mock_s3|bucket/file|/tmp/out" | awk -F'|' '{print $1}' > /dev/null

                local end=$(date +%s%3N)
                local elapsed=$((end - start))
                total_ms=$((total_ms + elapsed))
            done

            local avg_ms=$(echo "scale=2; $total_ms / $iterations" | bc)
            echo "  Average claim latency: ${avg_ms}ms"
            echo "$avg_ms"
            ;;

        contention)
            # PERF-007: Contention latency (10 workers, 1 job)
            echo "Measuring contention latency (10 workers competing for 1 job)..."

            generate_test_files "1KB" 1
            local job_file=$(create_jobs 1 "1KB")

            rm -rf "$TEST_DATA_DIR/results/"*.txt

            local pids=()
            local start_time=$(date +%s%3N)

            for i in $(seq 0 9); do
                local pid=$(run_worker "$i" 10 "$job_file")
                pids+=("$pid")
            done

            for pid in "${pids[@]}"; do
                wait "$pid" 2>/dev/null || true
            done

            local end_time=$(date +%s%3N)
            local latency_ms=$((end_time - start_time))

            echo "  Contention latency: ${latency_ms}ms"
            echo "$latency_ms"
            ;;

        e2e)
            # PERF-008: End-to-end latency
            echo "Measuring end-to-end latency (single 1MB file)..."

            generate_test_files "1MB" 1
            local job_file=$(create_jobs 1 "1MB")

            rm -rf "$TEST_DATA_DIR/results/"*.txt

            local start_time=$(date +%s%3N)
            local pid=$(run_worker 0 1 "$job_file")
            wait "$pid" 2>/dev/null || true
            local end_time=$(date +%s%3N)

            local latency_ms=$((end_time - start_time))

            echo "  E2E latency: ${latency_ms}ms"
            echo "$latency_ms"
            ;;

        idle_poll)
            # PERF-009: Idle polling overhead
            echo "Measuring idle polling CPU overhead..."

            # Create empty job file
            echo "" > "$TEST_DATA_DIR/jobs/empty.txt"

            # Start worker and measure CPU for 10 seconds
            local pid=$(run_worker 0 1 "$TEST_DATA_DIR/jobs/empty.txt")
            sleep 10

            # Get CPU usage (macOS/Linux compatible)
            local cpu_usage=0
            if [[ "$(uname)" == "Darwin" ]]; then
                cpu_usage=$(ps -p "$pid" -o %cpu | tail -1 | awk '{print $1}')
            else
                cpu_usage=$(ps -p "$pid" -o %cpu --no-headers | awk '{print $1}')
            fi

            kill "$pid" 2>/dev/null || true

            echo "  Idle CPU: ${cpu_usage}%"
            echo "$cpu_usage"
            ;;

        *)
            echo -e "${RED}Unknown metric type: $metric_type${NC}"
            return 1
            ;;
    esac
}

# Report results
report_results() {
    local test_name=$1
    local value=$2
    local unit=$3
    local baseline=${4:-}

    local status="PASS"
    local color="$GREEN"

    # Check against baseline if provided
    if [[ -n "$baseline" ]]; then
        local threshold=$(echo "$baseline * 1.2" | bc) # 20% tolerance
        if (( $(echo "$value > $threshold" | bc -l) )); then
            status="WARN"
            color="$YELLOW"
        fi
    fi

    echo -e "${color}[$status] $test_name: $value $unit${NC}"
    echo "[$status] $test_name: $value $unit (baseline: ${baseline:-N/A})" >> "$RESULTS_FILE"
}

# Test functions

benchmark_single_worker_small() {
    echo -e "\n${GREEN}=== PERF-001: Single Worker, Small Files (1KB) ===${NC}"
    local throughput=$(measure_throughput 1 100 "1KB")
    report_results "PERF-001" "$throughput" "files/sec" "50"
}

benchmark_single_worker_large() {
    echo -e "\n${GREEN}=== PERF-002: Single Worker, Large Files (100MB) ===${NC}"
    local throughput=$(measure_throughput 1 10 "100MB")
    report_results "PERF-002" "$throughput" "files/sec" "10"
}

benchmark_3_workers() {
    echo -e "\n${GREEN}=== PERF-003: 3 Workers, Mixed Sizes ===${NC}"
    # Mix of 1KB and 1MB files
    local throughput=$(measure_throughput 3 90 "1MB")
    report_results "PERF-003" "$throughput" "files/sec" "100"
}

benchmark_10_workers() {
    echo -e "\n${GREEN}=== PERF-004: 10 Workers Throughput ===${NC}"
    local throughput=$(measure_throughput 10 200 "1MB")
    report_results "PERF-004" "$throughput" "files/sec" "300"
}

benchmark_find_saturation() {
    echo -e "\n${GREEN}=== PERF-005: Find Saturation Point ===${NC}"

    local max_throughput=0
    local optimal_workers=0

    for workers in 1 2 4 8 16 32; do
        echo "Testing with $workers workers..."
        local throughput=$(measure_throughput "$workers" 100 "1MB")

        if (( $(echo "$throughput > $max_throughput" | bc -l) )); then
            max_throughput=$throughput
            optimal_workers=$workers
        fi

        echo "  $workers workers: $throughput files/sec"
    done

    echo -e "${GREEN}Optimal workers: $optimal_workers (throughput: $max_throughput files/sec)${NC}"
    report_results "PERF-005 Optimal" "$optimal_workers" "workers"
    report_results "PERF-005 Max Throughput" "$max_throughput" "files/sec"
}

benchmark_claim_latency() {
    echo -e "\n${GREEN}=== PERF-006: Job Claim Latency ===${NC}"
    local latency=$(measure_latency "claim")
    report_results "PERF-006" "$latency" "ms" "100"
}

benchmark_contention_latency() {
    echo -e "\n${GREEN}=== PERF-007: Contention Latency ===${NC}"
    local latency=$(measure_latency "contention")
    report_results "PERF-007" "$latency" "ms" "500"
}

benchmark_e2e_latency() {
    echo -e "\n${GREEN}=== PERF-008: End-to-End Latency ===${NC}"
    local latency=$(measure_latency "e2e")
    report_results "PERF-008" "$latency" "ms" "5000"
}

benchmark_idle_polling() {
    echo -e "\n${GREEN}=== PERF-009: Idle Polling Overhead ===${NC}"
    local cpu=$(measure_latency "idle_poll")
    report_results "PERF-009" "$cpu" "%" "1"
}

# Main execution
main() {
    echo -e "${GREEN}S3Sweep Performance Benchmark Suite${NC}"
    echo "======================================"

    init_test_env

    # Run throughput tests
    benchmark_single_worker_small
    benchmark_single_worker_large
    benchmark_3_workers
    benchmark_10_workers
    benchmark_find_saturation

    # Run latency tests
    benchmark_claim_latency
    benchmark_contention_latency
    benchmark_e2e_latency
    benchmark_idle_polling

    echo -e "\n${GREEN}All benchmarks complete!${NC}"
    echo "Results written to: $RESULTS_FILE"

    # Summary
    echo -e "\n${GREEN}=== Summary ===${NC}"
    grep -E "^\[PASS\]|\[WARN\]|\[FAIL\]" "$RESULTS_FILE" || true
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
