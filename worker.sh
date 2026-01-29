#!/bin/bash
set -euo pipefail

#############################################
# s3sweep Worker - File-based Job Claiming
#############################################

# Configuration from environment
JOBS_DIR="${JOBS_DIR:-/jobs}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/etc/rclone/rclone.conf}"
IDLE_SLEEP_SEC="${IDLE_SLEEP_SEC:-1}"
DATA_DIR="${DATA_DIR:-/data}"
WORKER_ID="${WORKER_ID:-0}"

# Derive worker ID from hostname if not explicitly set
if [[ "${WORKER_ID}" == "0" ]] && [[ -n "${HOSTNAME:-}" ]]; then
  # Extract number from hostname like "rclone-worker-3"
  if [[ "${HOSTNAME}" =~ -([0-9]+)$ ]]; then
    WORKER_ID="${BASH_REMATCH[1]}"
  fi
fi

# Directory structure
PENDING_DIR="${JOBS_DIR}/pending"
PROCESSING_DIR="${JOBS_DIR}/processing"
DONE_DIR="${JOBS_DIR}/done"
FAILED_DIR="${JOBS_DIR}/failed"

# Global state
SHUTDOWN_REQUESTED=false
CURRENT_JOB_FILE=""

# rclone flags optimized for S3 GET operations
RCLONE_FLAGS=(
  --no-traverse
  --s3-no-check-bucket
  --s3-force-path-style
  --s3-disable-checksum
  --s3-chunk-size 16M
  --transfers 1
  --checkers 1
  --multi-thread-streams 0
  --buffer-size 4M
  --use-mmap
  --tcp-keepalive 30s
  --timeout 5m
  --contimeout 15s
  --low-level-retries 3
  --retries 1
  --retries-sleep 2s
  --stats 0
  --log-level ERROR
)

#############################################
# Logging Functions
#############################################

log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Structured JSON logging
  jq -nc \
    --arg ts "$timestamp" \
    --arg lvl "$level" \
    --arg wid "$WORKER_ID" \
    --arg msg "$message" \
    '{timestamp: $ts, level: $lvl, worker_id: $wid, message: $msg}'
}

log_job() {
  local level="$1"
  local job_file="$2"
  local elapsed_ms="${3:-0}"
  local message="$4"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  jq -nc \
    --arg ts "$timestamp" \
    --arg lvl "$level" \
    --arg wid "$WORKER_ID" \
    --arg jf "$job_file" \
    --argjson el "$elapsed_ms" \
    --arg msg "$message" \
    '{timestamp: $ts, level: $lvl, worker_id: $wid, job_file: $jf, elapsed_ms: $el, message: $msg}'
}

#############################################
# Signal Handlers
#############################################

handle_shutdown() {
  rm -f /tmp/healthy
  log "WARN" "Shutdown signal received, finishing current job..."
  SHUTDOWN_REQUESTED=true
}

trap handle_shutdown SIGTERM SIGINT

#############################################
# Job Processing
#############################################

claim_job() {
  # Find oldest job file in pending directory
  local job_file
  job_file=$(find "$PENDING_DIR" -type f -name "*.txt" 2>/dev/null | sort | head -n1)

  if [[ -z "$job_file" ]]; then
    return 1  # No jobs available
  fi

  local job_basename
  job_basename=$(basename "$job_file")
  local claimed_file="${PROCESSING_DIR}/${job_basename%.txt}.worker-${WORKER_ID}.txt"

  # Atomic claim: mv fails if another worker claimed it first
  if mv "$job_file" "$claimed_file" 2>/dev/null; then
    echo "$claimed_file"
    return 0
  else
    return 1  # Another worker claimed it
  fi
}

process_job() {
  local job_file="$1"
  local job_basename
  job_basename=$(basename "$job_file")

  CURRENT_JOB_FILE="$job_file"
  local start_time
  start_time=$(date +%s%3N)  # milliseconds

  # Read job specification (one line: remote|src_path|dst_path)
  if [[ ! -f "$job_file" ]]; then
    log_job "ERROR" "$job_basename" 0 "Job file disappeared"
    CURRENT_JOB_FILE=""
    return 1
  fi

  local job_spec
  job_spec=$(head -n1 "$job_file")

  if [[ -z "$job_spec" ]]; then
    log_job "ERROR" "$job_basename" 0 "Empty job file"
    mv "$job_file" "${FAILED_DIR}/${job_basename}" 2>/dev/null || true
    CURRENT_JOB_FILE=""
    return 1
  fi

  # Validate field count (exactly 2 pipes expected)
  local pipe_count
  pipe_count=$(echo "$job_spec" | tr -cd '|' | wc -c)
  if [[ "$pipe_count" -ne 2 ]]; then
    log_job "ERROR" "$job_basename" 0 "Invalid job format: expected 2 field separators, got $pipe_count"
    mv "$job_file" "${FAILED_DIR}/${job_basename}" 2>/dev/null || true
    CURRENT_JOB_FILE=""
    return 1
  fi

  # Parse job specification
  IFS='|' read -r remote_name src_path dst_path <<< "$job_spec"

  if [[ -z "$remote_name" ]] || [[ -z "$src_path" ]] || [[ -z "$dst_path" ]]; then
    log_job "ERROR" "$job_basename" 0 "Invalid job format: $job_spec"
    mv "$job_file" "${FAILED_DIR}/${job_basename}" 2>/dev/null || true
    CURRENT_JOB_FILE=""
    return 1
  fi

  log_job "INFO" "$job_basename" 0 "Starting: ${remote_name}:${src_path} -> ${dst_path}"

  # Ensure destination directory exists
  local dst_dir
  dst_dir=$(dirname "$dst_path")
  mkdir -p "$dst_dir" 2>/dev/null || {
    log_job "ERROR" "$job_basename" 0 "Failed to create destination directory: $dst_dir"
    mv "$job_file" "${FAILED_DIR}/${job_basename}" 2>/dev/null || true
    CURRENT_JOB_FILE=""
    return 1
  }

  # Execute rclone copyto
  local rclone_src="${remote_name}:${src_path}"
  local rclone_exit=0

  rclone copyto \
    --config "$RCLONE_CONFIG" \
    "${RCLONE_FLAGS[@]}" \
    "$rclone_src" \
    "$dst_path" 2>&1 | while IFS= read -r line; do
      log "DEBUG" "rclone: $line"
    done
  rclone_exit="${PIPESTATUS[0]}"

  local end_time
  end_time=$(date +%s%3N)
  local elapsed_ms=$((end_time - start_time))

  if [[ "$rclone_exit" -eq 0 ]]; then
    log_job "INFO" "$job_basename" "$elapsed_ms" "SUCCESS"
    mv "$job_file" "${DONE_DIR}/${job_basename}" 2>/dev/null || {
      log_job "WARN" "$job_basename" "$elapsed_ms" "Completed but failed to move to done/"
    }
    CURRENT_JOB_FILE=""
    return 0
  else
    log_job "ERROR" "$job_basename" "$elapsed_ms" "FAILED (rclone exit $rclone_exit)"
    mv "$job_file" "${FAILED_DIR}/${job_basename}" 2>/dev/null || {
      log_job "WARN" "$job_basename" "$elapsed_ms" "Failed but could not move to failed/"
    }
    CURRENT_JOB_FILE=""
    return 1
  fi
}

#############################################
# Main Loop
#############################################

main() {
  log "INFO" "Worker starting (ID=$WORKER_ID, JOBS_DIR=$JOBS_DIR)"

  # Verify rclone config exists
  if [[ ! -f "$RCLONE_CONFIG" ]]; then
    log "FATAL" "rclone config not found: $RCLONE_CONFIG"
    exit 1
  fi

  # Ensure job directories exist
  mkdir -p "$PENDING_DIR" "$PROCESSING_DIR" "$DONE_DIR" "$FAILED_DIR"

  # Verify data directory is writable
  if [[ ! -w "$DATA_DIR" ]]; then
    log "FATAL" "Data directory not writable: $DATA_DIR"
    exit 1
  fi

  log "INFO" "Worker ready, polling for jobs..."
  touch /tmp/healthy

  while [[ "$SHUTDOWN_REQUESTED" == "false" ]]; do
    local claimed_job

    if claimed_job=$(claim_job); then
      process_job "$claimed_job" || true  # Continue on job failure
    else
      # No jobs available, sleep briefly
      sleep "$IDLE_SLEEP_SEC"
    fi
  done

  log "INFO" "Worker shutting down gracefully"
  exit 0
}

main "$@"
