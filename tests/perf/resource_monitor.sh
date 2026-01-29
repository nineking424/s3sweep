#!/bin/bash
set -euo pipefail

# resource_monitor.sh - Resource monitoring tests for s3sweep
#
# Test IDs:
#   PERF-010: Memory usage (idle)
#   PERF-011: Memory usage (active)
#   PERF-012: CPU usage (idle)
#   PERF-013: CPU usage (active)
#   PERF-014: Memory leak detection

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DATA_DIR="/tmp/s3sweep_resource_test"
RESULTS_FILE="${RESULTS_FILE:-/tmp/s3sweep_resource_results.txt}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Baselines
BASELINE_MEMORY_IDLE_MB=50
BASELINE_MEMORY_ACTIVE_MB=200
BASELINE_CPU_IDLE_PCT=1
BASELINE_CPU_ACTIVE_PCT=80

# Initialize test environment
init_test_env() {
    echo "Initializing resource monitor environment..."
    rm -rf "$TEST_DATA_DIR"
    mkdir -p "$TEST_DATA_DIR"/{jobs,results,data,downloads}

    echo "# S3Sweep Resource Monitor Results - $(date)" > "$RESULTS_FILE"
    echo "" >> "$RESULTS_FILE"

    echo "Test environment ready"
}

# Get memory usage in MB (cross-platform)
get_memory_mb() {
    local pid=$1

    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: use ps with RSS in KB
        local rss_kb=$(ps -p "$pid" -o rss= 2>/dev/null || echo 0)
        echo "scale=2; $rss_kb / 1024" | bc
    else
        # Linux: use ps with RSS in KB
        local rss_kb=$(ps -p "$pid" -o rss= --no-headers 2>/dev/null || echo 0)
        echo "scale=2; $rss_kb / 1024" | bc
    fi
}

# Get CPU usage (cross-platform)
get_cpu_pct() {
    local pid=$1

    if [[ "$(uname)" == "Darwin" ]]; then
        ps -p "$pid" -o %cpu= 2>/dev/null | awk '{print $1}' || echo 0
    else
        ps -p "$pid" -o %cpu= --no-headers 2>/dev/null | awk '{print $1}' || echo 0
    fi
}

# Generate test files
generate_test_files() {
    local size=$1
    local count=$2
    local output_dir="$TEST_DATA_DIR/data"

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
        esac
    done
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

# Run worker
run_worker() {
    local worker_id=$1
    local total_workers=$2
    local job_file=$3
    local result_file="$TEST_DATA_DIR/results/worker_${worker_id}.txt"

    cat > "$TEST_DATA_DIR/worker_${worker_id}_fetch.sh" <<EOF
fetch_jobs() {
    awk -F'|' -v id=$worker_id -v total=$total_workers '
        (NR - 1) % total == id { print }
    ' "$job_file"
}
EOF

    cat > "$TEST_DATA_DIR/worker_${worker_id}_send.sh" <<EOF
send_result() {
    local job_id=\$1
    local status=\$2
    local elapsed_ms=\$3
    echo "\$(date +%s%3N)|\$job_id|\$status|\$elapsed_ms" >> "$result_file"
}
EOF

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

            send_result "$job_id" "$status" "$elapsed"
        done < <(fetch_jobs)
    ' &

    echo $!
}

# Report results
report_results() {
    local test_name=$1
    local metric=$2
    local value=$3
    local unit=$4
    local baseline=${5:-}

    local status="PASS"
    local color="$GREEN"

    if [[ -n "$baseline" ]]; then
        local threshold=$(echo "$baseline * 1.2" | bc)
        if (( $(echo "$value > $threshold" | bc -l) )); then
            status="WARN"
            color="$YELLOW"
        fi
    fi

    echo -e "${color}[$status] $test_name - $metric: $value $unit (baseline: ${baseline:-N/A})${NC}"
    echo "[$status] $test_name - $metric: $value $unit (baseline: ${baseline:-N/A})" >> "$RESULTS_FILE"
}

# Monitor memory (idle)
monitor_memory_idle() {
    echo -e "\n${GREEN}=== PERF-010: Memory Usage (Idle) ===${NC}"

    # Create empty job file
    echo "" > "$TEST_DATA_DIR/jobs/empty.txt"

    # Start worker
    local pid=$(run_worker 0 1 "$TEST_DATA_DIR/jobs/empty.txt")

    sleep 2  # Let process stabilize

    # Sample memory for 30 seconds
    local samples=10
    local total_mb=0

    for i in $(seq 1 "$samples"); do
        local mem_mb=$(get_memory_mb "$pid")
        total_mb=$(echo "$total_mb + $mem_mb" | bc)
        echo "  Sample $i: ${mem_mb} MB"
        sleep 3
    done

    local avg_mb=$(echo "scale=2; $total_mb / $samples" | bc)

    kill "$pid" 2>/dev/null || true

    report_results "PERF-010" "Avg Memory Idle" "$avg_mb" "MB" "$BASELINE_MEMORY_IDLE_MB"
}

# Monitor memory (active)
monitor_memory_active() {
    echo -e "\n${GREEN}=== PERF-011: Memory Usage (Active) ===${NC}"

    generate_test_files "1MB" 100
    local job_file=$(create_jobs 100 "1MB")

    rm -rf "$TEST_DATA_DIR/results/"*.txt

    local pid=$(run_worker 0 1 "$job_file")

    sleep 2  # Let it start

    # Sample memory while processing
    local samples=10
    local total_mb=0

    for i in $(seq 1 "$samples"); do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "  Worker completed early"
            break
        fi

        local mem_mb=$(get_memory_mb "$pid")
        total_mb=$(echo "$total_mb + $mem_mb" | bc)
        echo "  Sample $i: ${mem_mb} MB"
        sleep 1
    done

    local avg_mb=$(echo "scale=2; $total_mb / $samples" | bc)

    wait "$pid" 2>/dev/null || true

    report_results "PERF-011" "Avg Memory Active" "$avg_mb" "MB" "$BASELINE_MEMORY_ACTIVE_MB"
}

# Monitor CPU (idle)
monitor_cpu_idle() {
    echo -e "\n${GREEN}=== PERF-012: CPU Usage (Idle) ===${NC}"

    echo "" > "$TEST_DATA_DIR/jobs/empty.txt"

    local pid=$(run_worker 0 1 "$TEST_DATA_DIR/jobs/empty.txt")

    sleep 5  # Let process stabilize

    # Sample CPU for 30 seconds
    local samples=10
    local total_cpu=0

    for i in $(seq 1 "$samples"); do
        local cpu_pct=$(get_cpu_pct "$pid")
        total_cpu=$(echo "$total_cpu + $cpu_pct" | bc)
        echo "  Sample $i: ${cpu_pct}%"
        sleep 3
    done

    local avg_cpu=$(echo "scale=2; $total_cpu / $samples" | bc)

    kill "$pid" 2>/dev/null || true

    report_results "PERF-012" "Avg CPU Idle" "$avg_cpu" "%" "$BASELINE_CPU_IDLE_PCT"
}

# Monitor CPU (active)
monitor_cpu_active() {
    echo -e "\n${GREEN}=== PERF-013: CPU Usage (Active) ===${NC}"

    generate_test_files "1MB" 100
    local job_file=$(create_jobs 100 "1MB")

    rm -rf "$TEST_DATA_DIR/results/"*.txt

    local pid=$(run_worker 0 1 "$job_file")

    sleep 2

    # Sample CPU while processing
    local samples=10
    local total_cpu=0

    for i in $(seq 1 "$samples"); do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "  Worker completed early"
            break
        fi

        local cpu_pct=$(get_cpu_pct "$pid")
        total_cpu=$(echo "$total_cpu + $cpu_pct" | bc)
        echo "  Sample $i: ${cpu_pct}%"
        sleep 1
    done

    local avg_cpu=$(echo "scale=2; $total_cpu / $samples" | bc)

    wait "$pid" 2>/dev/null || true

    report_results "PERF-013" "Avg CPU Active" "$avg_cpu" "%" "$BASELINE_CPU_ACTIVE_PCT"
}

# Detect memory leak
detect_memory_leak() {
    echo -e "\n${GREEN}=== PERF-014: Memory Leak Detection ===${NC}"

    generate_test_files "1KB" 1000
    local job_file=$(create_jobs 1000 "1KB")

    rm -rf "$TEST_DATA_DIR/results/"*.txt

    local pid=$(run_worker 0 1 "$job_file")

    sleep 2

    # Track memory over time
    local start_mem=$(get_memory_mb "$pid")
    echo "  Initial memory: ${start_mem} MB"

    local samples=20
    local prev_mem=$start_mem
    local leak_detected=false

    for i in $(seq 1 "$samples"); do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "  Worker completed"
            break
        fi

        sleep 2

        local current_mem=$(get_memory_mb "$pid")
        local delta=$(echo "$current_mem - $prev_mem" | bc)

        echo "  Sample $i: ${current_mem} MB (delta: ${delta} MB)"

        # Check for consistent growth (leak indicator)
        if (( $(echo "$delta > 5" | bc -l) )); then
            echo -e "  ${YELLOW}WARNING: Significant memory increase detected${NC}"
            leak_detected=true
        fi

        prev_mem=$current_mem
    done

    wait "$pid" 2>/dev/null || true

    local end_mem=$(get_memory_mb "$pid" 2>/dev/null || echo "$prev_mem")
    local total_growth=$(echo "$end_mem - $start_mem" | bc)

    echo "  Final memory: ${end_mem} MB"
    echo "  Total growth: ${total_growth} MB"

    local status="PASS"
    if [[ "$leak_detected" == "true" ]] || (( $(echo "$total_growth > 50" | bc -l) )); then
        status="WARN"
    fi

    report_results "PERF-014" "Memory Growth" "$total_growth" "MB" "10"
    report_results "PERF-014" "Leak Status" "$status" "" ""
}

# Main execution
main() {
    echo -e "${GREEN}S3Sweep Resource Monitor Suite${NC}"
    echo "======================================"

    init_test_env

    monitor_memory_idle
    monitor_memory_active
    monitor_cpu_idle
    monitor_cpu_active
    detect_memory_leak

    echo -e "\n${GREEN}Resource monitoring complete!${NC}"
    echo "Results written to: $RESULTS_FILE"

    echo -e "\n${GREEN}=== Summary ===${NC}"
    grep -E "^\[PASS\]|\[WARN\]|\[FAIL\]" "$RESULTS_FILE" || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
