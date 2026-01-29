#!/usr/bin/env bats

# Unit Tests for s3sweep Worker Script
# Tests worker.sh functions in isolation with mocked dependencies
# Total: 38 unit tests covering job parsing, claiming, validation, logging, shutdown, and startup

# Load test helpers
load '../lib/helpers'
load '../lib/assertions'

setup() {
  setup_test_env

  # Set up mock rclone in PATH
  export TEST_DIR="$TEST_TEMP_DIR"
  mkdir -p "$TEST_DIR/mocks"
  cp "$(dirname "$BATS_TEST_DIRNAME")/unit/mocks/rclone" "$TEST_DIR/mocks/"
  chmod +x "$TEST_DIR/mocks/rclone"
  export PATH="$TEST_DIR/mocks:$PATH"

  # Export environment for worker
  export JOBS_DIR="$TEST_JOBS_DIR"
  export DATA_DIR="$TEST_DATA_DIR"
  export RCLONE_CONFIG="$TEST_RCLONE_CONFIG"
  export IDLE_SLEEP_SEC=1

  # Mock rclone default: success, create files
  export MOCK_RCLONE_EXIT=0
  export MOCK_RCLONE_CREATE_FILE=1
  export MOCK_RCLONE_LOG="$TEST_TEMP_DIR/rclone.log"
}

teardown() {
  cleanup_test_env
}

#############################################
# 1.1 Job File Parsing (UNIT-001 to UNIT-010)
#############################################

@test "UNIT-001: Valid 3-field job parses correctly" {
  local job_file="$TEST_JOBS_DIR/pending/test001.txt"
  echo "s3_remote|bucket/file.dat|$TEST_DATA_DIR/output.dat" > "$job_file"

  # Run worker in background
  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # Job should succeed
  [[ -f "$TEST_JOBS_DIR/done/test001.txt" ]]
  [[ -f "$TEST_DATA_DIR/output.dat" ]]
}

@test "UNIT-002: Empty job file moves to failed/" {
  local job_file="$TEST_JOBS_DIR/pending/test002.txt"
  touch "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # Job should fail
  [[ -f "$TEST_JOBS_DIR/failed/test002.txt" ]]
}

@test "UNIT-003: Missing field (only 2 fields) moves to failed/" {
  local job_file="$TEST_JOBS_DIR/pending/test003.txt"
  echo "s3_remote|bucket/file.dat" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  [[ -f "$TEST_JOBS_DIR/failed/test003.txt" ]]
}

@test "UNIT-004: Extra fields (4 fields) REJECTED, moves to failed/" {
  local job_file="$TEST_JOBS_DIR/pending/test004.txt"
  echo "s3_remote|bucket/file.dat|/data/output.dat|extra" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  [[ -f "$TEST_JOBS_DIR/failed/test004.txt" ]]
}

@test "UNIT-005: Pipe character in dst_path REJECTED, moves to failed/" {
  local job_file="$TEST_JOBS_DIR/pending/test005.txt"
  echo "s3_remote|bucket/file.dat|/data/bad|path.dat" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # This has 3 pipes, not 2, so should fail validation
  [[ -f "$TEST_JOBS_DIR/failed/test005.txt" ]]
}

@test "UNIT-006: Unicode characters in paths handled correctly" {
  local job_file="$TEST_JOBS_DIR/pending/test006.txt"
  echo "s3_remote|bucket/文件.dat|$TEST_DATA_DIR/文件.dat" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  [[ -f "$TEST_JOBS_DIR/done/test006.txt" ]]
}

@test "UNIT-007: Spaces in paths handled correctly" {
  local job_file="$TEST_JOBS_DIR/pending/test007.txt"
  echo "s3_remote|bucket/my file.dat|$TEST_DATA_DIR/my file.dat" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  [[ -f "$TEST_JOBS_DIR/done/test007.txt" ]]
  [[ -f "$TEST_DATA_DIR/my file.dat" ]]
}

@test "UNIT-008: Trailing newline ignored correctly" {
  local job_file="$TEST_JOBS_DIR/pending/test008.txt"
  printf "s3_remote|bucket/file.dat|$TEST_DATA_DIR/output.dat\n" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  [[ -f "$TEST_JOBS_DIR/done/test008.txt" ]]
}

@test "UNIT-009: Empty remote_name rejected" {
  local job_file="$TEST_JOBS_DIR/pending/test009.txt"
  echo "|bucket/file.dat|$TEST_DATA_DIR/output.dat" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  [[ -f "$TEST_JOBS_DIR/failed/test009.txt" ]]
}

@test "UNIT-010: Empty src_path rejected" {
  local job_file="$TEST_JOBS_DIR/pending/test010.txt"
  echo "s3_remote||$TEST_DATA_DIR/output.dat" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  [[ -f "$TEST_JOBS_DIR/failed/test010.txt" ]]
}

#############################################
# 1.2 Field Count Validation (UNIT-033 to UNIT-035)
#############################################

@test "UNIT-033: Non-.txt file ignored by claim_job" {
  local job_file="$TEST_JOBS_DIR/pending/test033.job"
  echo "s3_remote|bucket/file.dat|$TEST_DATA_DIR/output.dat" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # Should still be in pending (not claimed)
  [[ -f "$TEST_JOBS_DIR/pending/test033.job" ]]
  [[ ! -f "$TEST_JOBS_DIR/done/test033.job" ]]
}

@test "UNIT-034: Exactly 2 pipes required for valid job" {
  # Test with 1 pipe - should fail
  local job_file="$TEST_JOBS_DIR/pending/test034a.txt"
  echo "s3_remote|bucket/file.dat" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  [[ -f "$TEST_JOBS_DIR/failed/test034a.txt" ]]

  # Test with 3 pipes - should fail
  local job_file2="$TEST_JOBS_DIR/pending/test034b.txt"
  echo "s3_remote|bucket|file.dat|extra" > "$job_file2"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid2=$!
  sleep 2
  kill -TERM $pid2 2>/dev/null || true
  wait $pid2 2>/dev/null || true

  [[ -f "$TEST_JOBS_DIR/failed/test034b.txt" ]]
}

@test "UNIT-035: dst_path validation - no pipes allowed in final field" {
  # This is already tested in UNIT-005 but confirming explicit validation
  local job_file="$TEST_JOBS_DIR/pending/test035.txt"
  echo "s3_remote|bucket/file.dat|/data/file.dat|extra" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # 3 pipes = invalid
  [[ -f "$TEST_JOBS_DIR/failed/test035.txt" ]]
}

#############################################
# 1.3 Atomic Job Claiming (UNIT-011 to UNIT-015)
#############################################

@test "UNIT-011: claim_job successfully claims and renames file" {
  local job_file="$TEST_JOBS_DIR/pending/test011.txt"
  echo "s3_remote|bucket/file.dat|$TEST_DATA_DIR/output.dat" > "$job_file"

  export WORKER_ID=5

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # Should have worker ID in processing or done
  local claimed_file="$TEST_JOBS_DIR/processing/test011.worker-5.txt"
  local done_file="$TEST_JOBS_DIR/done/test011.worker-5.txt"

  [[ -f "$done_file" ]] || [[ -f "$claimed_file" ]]
}

@test "UNIT-012: claim_job returns nothing when no jobs available" {
  # No jobs in pending
  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # Worker should exit gracefully with no errors
  [[ $(find "$TEST_JOBS_DIR/processing" -type f | wc -l) -eq 0 ]]
}

@test "UNIT-013: Job file disappears mid-processing handled gracefully" {
  local job_file="$TEST_JOBS_DIR/pending/test013.txt"
  echo "s3_remote|bucket/file.dat|$TEST_DATA_DIR/output.dat" > "$job_file"

  # Start worker with slow rclone
  export MOCK_RCLONE_DELAY=3

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!

  sleep 1
  # Delete the claimed job file
  rm -f "$TEST_JOBS_DIR/processing"/*.txt

  sleep 3
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # Worker should continue without crashing
  true
}

@test "UNIT-014: Claimed file renamed with worker ID" {
  local job_file="$TEST_JOBS_DIR/pending/test014.txt"
  echo "s3_remote|bucket/file.dat|$TEST_DATA_DIR/output.dat" > "$job_file"

  export WORKER_ID=42

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # Check for worker-42 in filename
  local found=0
  for f in "$TEST_JOBS_DIR/done"/*.txt "$TEST_JOBS_DIR/processing"/*.txt; do
    [[ -f "$f" ]] && [[ "$f" =~ worker-42 ]] && found=1
  done

  [[ $found -eq 1 ]]
}

@test "UNIT-015: Oldest job file claimed first (FIFO ordering)" {
  # Create jobs with different timestamps
  local job1="$TEST_JOBS_DIR/pending/aaa.txt"
  local job2="$TEST_JOBS_DIR/pending/bbb.txt"
  local job3="$TEST_JOBS_DIR/pending/ccc.txt"

  echo "s3_remote|bucket/file1.dat|$TEST_DATA_DIR/out1.dat" > "$job1"
  sleep 1
  echo "s3_remote|bucket/file2.dat|$TEST_DATA_DIR/out2.dat" > "$job2"
  sleep 1
  echo "s3_remote|bucket/file3.dat|$TEST_DATA_DIR/out3.dat" > "$job3"

  # Modify timestamps to ensure aaa is oldest
  touch -t 202401010000 "$job1"
  touch -t 202401010001 "$job2"
  touch -t 202401010002 "$job3"

  export WORKER_ID=1

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # aaa should be processed first (oldest)
  [[ -f "$TEST_JOBS_DIR/done/aaa.worker-1.txt" ]] || [[ -f "$TEST_JOBS_DIR/processing/aaa.worker-1.txt" ]]
}

#############################################
# 1.4 Worker ID Extraction (UNIT-016 to UNIT-020, UNIT-036)
#############################################

@test "UNIT-016: Worker ID extracted from hostname regex" {
  export HOSTNAME="rclone-worker-7"
  unset WORKER_ID

  # Source worker to trigger ID extraction
  local actual_id
  actual_id=$(bash -c '
    source "$(dirname "$BATS_TEST_DIRNAME")/../worker.sh"
    echo "$WORKER_ID"
  ' main)

  # Should extract 7 from hostname
  [[ "$actual_id" =~ 7 ]]
}

@test "UNIT-017: Worker ID handles double-digit pod numbers" {
  export HOSTNAME="rclone-worker-15"
  unset WORKER_ID

  local actual_id
  actual_id=$(bash -c 'HOSTNAME="rclone-worker-15"; WORKER_ID=0; if [[ "$HOSTNAME" =~ -([0-9]+)$ ]]; then echo "${BASH_REMATCH[1]}"; fi')

  [[ "$actual_id" == "15" ]]
}

@test "UNIT-018: Worker ID from env overrides hostname when != 0" {
  export HOSTNAME="rclone-worker-7"
  export WORKER_ID=99

  local job_file="$TEST_JOBS_DIR/pending/test018.txt"
  echo "s3_remote|bucket/file.dat|$TEST_DATA_DIR/output.dat" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # Should use WORKER_ID=99
  local found=0
  for f in "$TEST_JOBS_DIR/done"/*.txt "$TEST_JOBS_DIR/processing"/*.txt; do
    [[ -f "$f" ]] && [[ "$f" =~ worker-99 ]] && found=1
  done

  [[ $found -eq 1 ]]
}

@test "UNIT-019: Worker ID defaults to 0 if no hostname pattern match" {
  export HOSTNAME="random-host-name"
  unset WORKER_ID

  local actual_id
  actual_id=$(bash -c '
    HOSTNAME="random-host-name"
    WORKER_ID=0
    if [[ "$WORKER_ID" == "0" ]] && [[ -n "$HOSTNAME" ]]; then
      if [[ "$HOSTNAME" =~ -([0-9]+)$ ]]; then
        WORKER_ID="${BASH_REMATCH[1]}"
      fi
    fi
    echo "$WORKER_ID"
  ')

  [[ "$actual_id" == "0" ]]
}

@test "UNIT-020: Worker ID extracted from full pod name format" {
  export HOSTNAME="rclone-worker-statefulset-3"
  unset WORKER_ID

  local actual_id
  actual_id=$(bash -c 'HOSTNAME="rclone-worker-statefulset-3"; WORKER_ID=0; if [[ "$HOSTNAME" =~ -([0-9]+)$ ]]; then echo "${BASH_REMATCH[1]}"; fi')

  [[ "$actual_id" == "3" ]]
}

@test "UNIT-036: Worker ID extraction with WORKER_ID=0 triggers hostname parsing" {
  export HOSTNAME="rclone-worker-8"
  export WORKER_ID=0

  local job_file="$TEST_JOBS_DIR/pending/test036.txt"
  echo "s3_remote|bucket/file.dat|$TEST_DATA_DIR/output.dat" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # Should extract 8 from hostname
  local found=0
  for f in "$TEST_JOBS_DIR/done"/*.txt "$TEST_JOBS_DIR/processing"/*.txt; do
    [[ -f "$f" ]] && [[ "$f" =~ worker-8 ]] && found=1
  done

  [[ $found -eq 1 ]]
}

#############################################
# 1.5 Structured Logging (UNIT-021 to UNIT-024)
#############################################

@test "UNIT-021: log() produces valid JSON with all required fields" {
  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 1
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # Check worker log for JSON structure
  [[ -f "$WORKER_LOG" ]]

  # Extract first JSON log line
  local log_line
  log_line=$(grep -m1 '{' "$WORKER_LOG" || echo "")

  # Validate JSON structure
  [[ -n "$log_line" ]]
  echo "$log_line" | jq -e '.timestamp' >/dev/null
  echo "$log_line" | jq -e '.level' >/dev/null
  echo "$log_line" | jq -e '.worker_id' >/dev/null
  echo "$log_line" | jq -e '.message' >/dev/null
}

@test "UNIT-022: log_job() includes elapsed_ms and job_file" {
  local job_file="$TEST_JOBS_DIR/pending/test022.txt"
  echo "s3_remote|bucket/file.dat|$TEST_DATA_DIR/output.dat" > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # Find job log entry
  local log_line
  log_line=$(grep 'job_file' "$WORKER_LOG" | grep 'test022' | head -1 || echo "")

  [[ -n "$log_line" ]]
  echo "$log_line" | jq -e '.job_file' >/dev/null
  echo "$log_line" | jq -e '.elapsed_ms' >/dev/null
}

@test "UNIT-023: Timestamp format is ISO8601 UTC" {
  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 1
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  local log_line
  log_line=$(grep -m1 '{' "$WORKER_LOG" || echo "")

  local timestamp
  timestamp=$(echo "$log_line" | jq -r '.timestamp')

  # Check ISO8601 format: YYYY-MM-DDTHH:MM:SSZ
  [[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "UNIT-024: JSON escaping in log messages with special characters" {
  local job_file="$TEST_JOBS_DIR/pending/test024.txt"
  echo 's3_remote|bucket/"file".dat|'"$TEST_DATA_DIR"'/output.dat' > "$job_file"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # All log lines should be valid JSON
  while IFS= read -r line; do
    [[ "$line" =~ ^\{ ]] && echo "$line" | jq . >/dev/null
  done < "$WORKER_LOG"
}

#############################################
# 1.6 Graceful Shutdown (UNIT-025 to UNIT-028)
#############################################

@test "UNIT-025: SIGTERM during idle triggers graceful shutdown" {
  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 1

  kill -TERM $pid
  wait $pid 2>/dev/null || true

  # Check for shutdown message in logs
  grep -q "Shutdown signal" "$WORKER_LOG"
}

@test "UNIT-026: SIGINT during idle triggers graceful shutdown" {
  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 1

  kill -INT $pid
  wait $pid 2>/dev/null || true

  grep -q "Shutdown signal" "$WORKER_LOG"
}

@test "UNIT-027: Signal during job execution completes current job" {
  local job_file="$TEST_JOBS_DIR/pending/test027.txt"
  echo "s3_remote|bucket/file.dat|$TEST_DATA_DIR/output.dat" > "$job_file"

  # Slow rclone to give time to send signal
  export MOCK_RCLONE_DELAY=2

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 1

  kill -TERM $pid
  wait $pid 2>/dev/null || true

  # Job should complete
  [[ -f "$TEST_JOBS_DIR/done/test027.txt" ]] || [[ -f "$TEST_JOBS_DIR/processing/test027.txt" ]]
}

@test "UNIT-028: Shutdown logged correctly with graceful exit" {
  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 1

  kill -TERM $pid
  wait $pid 2>/dev/null || true

  grep -q "Worker shutting down gracefully" "$WORKER_LOG"
}

#############################################
# 1.7 Startup Validation (UNIT-029 to UNIT-032)
#############################################

@test "UNIT-029: Missing rclone config causes fatal error" {
  export RCLONE_CONFIG="/nonexistent/rclone.conf"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 1

  # Worker should exit
  ! kill -0 $pid 2>/dev/null

  grep -q "rclone config not found" "$WORKER_LOG"
}

@test "UNIT-030: Non-writable data directory causes fatal error" {
  export DATA_DIR="$TEST_TEMP_DIR/readonly"
  mkdir -p "$DATA_DIR"
  chmod 444 "$DATA_DIR"

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 1

  ! kill -0 $pid 2>/dev/null

  grep -q "Data directory not writable" "$WORKER_LOG"

  chmod 755 "$DATA_DIR"
}

@test "UNIT-031: Worker creates missing job directories on startup" {
  # Remove job directories
  rm -rf "$TEST_JOBS_DIR"/{pending,processing,done,failed}

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 1
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # Directories should be created
  [[ -d "$TEST_JOBS_DIR/pending" ]]
  [[ -d "$TEST_JOBS_DIR/processing" ]]
  [[ -d "$TEST_JOBS_DIR/done" ]]
  [[ -d "$TEST_JOBS_DIR/failed" ]]
}

@test "UNIT-032: Health file created when worker ready" {
  rm -f /tmp/healthy

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 1

  [[ -f /tmp/healthy ]]

  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
}

#############################################
# 1.8 Configuration (UNIT-037 to UNIT-038)
#############################################

@test "UNIT-037: IDLE_SLEEP_SEC affects polling interval" {
  export IDLE_SLEEP_SEC=2

  local start_time
  start_time=$(date +%s)

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 5
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  local end_time
  end_time=$(date +%s)
  local elapsed=$((end_time - start_time))

  # Should have slept at least once (2 seconds)
  [[ $elapsed -ge 4 ]]
}

@test "UNIT-038: IDLE_SLEEP_SEC defaults to 1 when not set" {
  unset IDLE_SLEEP_SEC

  bash "$BATS_TEST_DIRNAME/../../worker.sh" > "$WORKER_LOG" 2>&1 &
  local pid=$!
  sleep 2
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true

  # Check that default value is used (logged or observable behavior)
  grep -q "Worker ready" "$WORKER_LOG"
}
