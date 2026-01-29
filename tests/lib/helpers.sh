#!/usr/bin/env bash
set -euo pipefail

# Test Helper Functions for s3sweep
# Provides common utilities for setting up test environments, managing workers, and handling test data

# Color codes for output
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RESET='\033[0m'

# Global variables for test environment
export TEST_TEMP_DIR=""
export TEST_JOBS_DIR=""
export TEST_DATA_DIR=""
export TEST_RCLONE_CONFIG=""
export WORKER_PID=""
export WORKER_LOG=""

#######################################
# Set up test environment with temporary directories
# Creates JOBS_DIR with subdirs, DATA_DIR, and mock rclone config
# Globals:
#   TEST_TEMP_DIR
#   TEST_JOBS_DIR
#   TEST_DATA_DIR
#   TEST_RCLONE_CONFIG
#   WORKER_LOG
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
setup_test_env() {
    TEST_TEMP_DIR=$(mktemp -d -t s3sweep-test.XXXXXX)
    TEST_JOBS_DIR="${TEST_TEMP_DIR}/jobs"
    TEST_DATA_DIR="${TEST_TEMP_DIR}/data"
    TEST_RCLONE_CONFIG="${TEST_TEMP_DIR}/rclone.conf"
    WORKER_LOG="${TEST_TEMP_DIR}/worker.log"

    # Create job directories
    mkdir -p "${TEST_JOBS_DIR}"/{pending,processing,done,failed}
    mkdir -p "${TEST_DATA_DIR}"

    # Create minimal rclone config
    cat > "${TEST_RCLONE_CONFIG}" <<EOF
[test_remote]
type = s3
provider = Other
env_auth = false
access_key_id = test_access_key
secret_access_key = test_secret_key
endpoint = http://localhost:9000
EOF

    echo -e "${COLOR_GREEN}[SETUP]${COLOR_RESET} Test environment created at ${TEST_TEMP_DIR}"
}

#######################################
# Clean up test environment
# Stops any running workers and removes temporary directories
# Globals:
#   TEST_TEMP_DIR
#   WORKER_PID
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
cleanup_test_env() {
    if [[ -n "${WORKER_PID:-}" ]] && kill -0 "${WORKER_PID}" 2>/dev/null; then
        stop_worker
    fi

    if [[ -n "${TEST_TEMP_DIR:-}" ]] && [[ -d "${TEST_TEMP_DIR}" ]]; then
        rm -rf "${TEST_TEMP_DIR}"
        echo -e "${COLOR_GREEN}[CLEANUP]${COLOR_RESET} Test environment removed"
    fi
}

#######################################
# Create a job file in pending directory
# Globals:
#   TEST_JOBS_DIR
# Arguments:
#   $1 - Job name (without .job extension)
#   $2 - Job content (job_id|remote_name|src_path|dst_path)
# Returns:
#   0 on success
#######################################
create_job() {
    local job_name="$1"
    local job_content="$2"
    local job_file="${TEST_JOBS_DIR}/pending/${job_name}.job"

    echo "${job_content}" > "${job_file}"
    echo -e "${COLOR_YELLOW}[JOB]${COLOR_RESET} Created job: ${job_name}"
}

#######################################
# Wait for job to complete (move to done or failed)
# Globals:
#   TEST_JOBS_DIR
# Arguments:
#   $1 - Job name (without .job extension)
#   $2 - Timeout in seconds (default: 30)
# Returns:
#   0 if job completed, 1 if timeout
#######################################
wait_for_job_complete() {
    local job_name="$1"
    local timeout="${2:-30}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if [[ -f "${TEST_JOBS_DIR}/done/${job_name}.job" ]] || \
           [[ -f "${TEST_JOBS_DIR}/failed/${job_name}.job" ]]; then
            echo -e "${COLOR_GREEN}[WAIT]${COLOR_RESET} Job ${job_name} completed in ${elapsed}s"
            return 0
        fi
        sleep 1
        ((elapsed++))
    done

    echo -e "${COLOR_RED}[WAIT]${COLOR_RESET} Job ${job_name} timed out after ${timeout}s"
    return 1
}

#######################################
# Start worker script in background
# Globals:
#   WORKER_PID
#   WORKER_LOG
#   TEST_JOBS_DIR
#   TEST_DATA_DIR
#   TEST_RCLONE_CONFIG
# Arguments:
#   $1 - Path to worker script
#   $2 - Additional environment variables (optional, format: "VAR1=val1 VAR2=val2")
# Returns:
#   0 on success
#######################################
start_worker() {
    local worker_script="$1"
    local env_vars="${2:-}"

    if [[ ! -f "${worker_script}" ]]; then
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} Worker script not found: ${worker_script}"
        return 1
    fi

    # Export test environment variables
    export JOBS_DIR="${TEST_JOBS_DIR}"
    export DATA_DIR="${TEST_DATA_DIR}"
    export RCLONE_CONFIG="${TEST_RCLONE_CONFIG}"
    export WORKER_ID="${WORKER_ID:-0}"
    export TOTAL_WORKERS="${TOTAL_WORKERS:-1}"

    # Start worker in background
    if [[ -n "${env_vars}" ]]; then
        env ${env_vars} bash "${worker_script}" > "${WORKER_LOG}" 2>&1 &
    else
        bash "${worker_script}" > "${WORKER_LOG}" 2>&1 &
    fi

    WORKER_PID=$!
    echo -e "${COLOR_GREEN}[WORKER]${COLOR_RESET} Started worker (PID: ${WORKER_PID})"

    # Wait briefly to ensure worker started
    sleep 1

    if ! kill -0 "${WORKER_PID}" 2>/dev/null; then
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} Worker failed to start"
        cat "${WORKER_LOG}"
        return 1
    fi
}

#######################################
# Stop worker gracefully with SIGTERM
# Globals:
#   WORKER_PID
#   WORKER_LOG
# Arguments:
#   $1 - Grace period in seconds before SIGKILL (default: 5)
# Returns:
#   0 on success
#######################################
stop_worker() {
    local grace_period="${1:-5}"

    if [[ -z "${WORKER_PID:-}" ]] || ! kill -0 "${WORKER_PID}" 2>/dev/null; then
        echo -e "${COLOR_YELLOW}[WORKER]${COLOR_RESET} Worker not running"
        return 0
    fi

    echo -e "${COLOR_YELLOW}[WORKER]${COLOR_RESET} Stopping worker (PID: ${WORKER_PID})"
    kill -TERM "${WORKER_PID}" 2>/dev/null || true

    # Wait for graceful shutdown
    local elapsed=0
    while kill -0 "${WORKER_PID}" 2>/dev/null && [[ $elapsed -lt $grace_period ]]; do
        sleep 1
        ((elapsed++))
    done

    # Force kill if still running
    if kill -0 "${WORKER_PID}" 2>/dev/null; then
        echo -e "${COLOR_RED}[WORKER]${COLOR_RESET} Force killing worker"
        kill -KILL "${WORKER_PID}" 2>/dev/null || true
    fi

    wait "${WORKER_PID}" 2>/dev/null || true
    WORKER_PID=""
    echo -e "${COLOR_GREEN}[WORKER]${COLOR_RESET} Worker stopped"
}

#######################################
# Get worker logs
# Globals:
#   WORKER_LOG
# Arguments:
#   $1 - Number of lines to tail (optional, default: all)
# Returns:
#   0 on success
#######################################
get_worker_logs() {
    local lines="${1:-}"

    if [[ ! -f "${WORKER_LOG}" ]]; then
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} Worker log not found: ${WORKER_LOG}"
        return 1
    fi

    if [[ -n "${lines}" ]]; then
        tail -n "${lines}" "${WORKER_LOG}"
    else
        cat "${WORKER_LOG}"
    fi
}

#######################################
# Print test section header
# Arguments:
#   $1 - Section title
# Returns:
#   0 on success
#######################################
test_section() {
    echo ""
    echo -e "${COLOR_YELLOW}========================================${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}$1${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}========================================${COLOR_RESET}"
}

#######################################
# Print test info message
# Arguments:
#   $@ - Message to print
# Returns:
#   0 on success
#######################################
test_info() {
    echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} $*"
}

#######################################
# Print test error message
# Arguments:
#   $@ - Message to print
# Returns:
#   0 on success
#######################################
test_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}
