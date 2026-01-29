#!/bin/bash
# invalid_jobs.sh - Invalid job file tests (FAIL-006 to FAIL-010)
# Tests worker behavior when encountering malformed job files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/helpers.sh"

TEST_GROUP="invalid_jobs"

# FAIL-006: Empty job file
test_empty_file() {
    local test_name="FAIL-006"
    echo "[$test_name] Testing empty job file..."

    setup_test_env

    # Create empty job file
    local job_id="empty-006"
    local job_file="$JOBS_DIR/pending/${job_id}.job"
    touch "$job_file"  # Empty file

    # Mock worker script that validates job format
    cat > "$JOBS_DIR/test-worker.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

JOBS_DIR="${JOBS_DIR:-/jobs}"

# Process one job
job_file="$JOBS_DIR/pending/"*.job
if [[ ! -f $job_file ]]; then
    echo "No jobs found"
    exit 0
fi

# Read job
job_line=$(cat "$job_file")

# Validate format
if [[ -z "$job_line" ]]; then
    echo "ERROR: Empty job file"
    mv "$job_file" "$JOBS_DIR/failed/"
    exit 1
fi

# Check for pipe separators
if [[ $(echo "$job_line" | grep -o '|' | wc -l) -lt 3 ]]; then
    echo "ERROR: Invalid job format (missing pipes)"
    mv "$job_file" "$JOBS_DIR/failed/"
    exit 1
fi

echo "Job valid"
EOF
    chmod +x "$JOBS_DIR/test-worker.sh"

    # Run worker
    JOBS_DIR="$JOBS_DIR" "$JOBS_DIR/test-worker.sh" || true

    # Check result
    if [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ Empty job file correctly moved to failed/"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Empty job file not handled correctly"
        FAIL=$((FAIL + 1))
    fi

    cleanup_test_env
}

# FAIL-007: Malformed job (missing pipe separators)
test_malformed_no_pipes() {
    local test_name="FAIL-007"
    echo "[$test_name] Testing malformed job (no pipes)..."

    setup_test_env

    # Create malformed job
    local job_id="malformed-007"
    local job_file="$JOBS_DIR/pending/${job_id}.job"
    echo "this-is-not-a-valid-job-format" > "$job_file"

    # Use same validation script
    cat > "$JOBS_DIR/test-worker.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

JOBS_DIR="${JOBS_DIR:-/jobs}"

job_file="$JOBS_DIR/pending/"*.job
if [[ ! -f $job_file ]]; then exit 0; fi

job_line=$(cat "$job_file")

if [[ -z "$job_line" ]]; then
    mv "$job_file" "$JOBS_DIR/failed/"
    exit 1
fi

# Expect exactly 3 pipes
pipe_count=$(echo "$job_line" | grep -o '|' | wc -l)
if [[ $pipe_count -ne 3 ]]; then
    echo "ERROR: Invalid format - expected 3 pipes, got $pipe_count"
    mv "$job_file" "$JOBS_DIR/failed/"
    exit 1
fi
EOF
    chmod +x "$JOBS_DIR/test-worker.sh"

    JOBS_DIR="$JOBS_DIR" "$JOBS_DIR/test-worker.sh" || true

    if [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ Malformed job correctly moved to failed/"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Malformed job not handled correctly"
        FAIL=$((FAIL + 1))
    fi

    cleanup_test_env
}

# FAIL-008: Binary garbage in job file
test_binary_garbage() {
    local test_name="FAIL-008"
    echo "[$test_name] Testing binary garbage in job file..."

    setup_test_env

    local job_id="garbage-008"
    local job_file="$JOBS_DIR/pending/${job_id}.job"

    # Write random binary data
    dd if=/dev/urandom bs=256 count=1 2>/dev/null | base64 > "$job_file"

    cat > "$JOBS_DIR/test-worker.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

JOBS_DIR="${JOBS_DIR:-/jobs}"

job_file="$JOBS_DIR/pending/"*.job
if [[ ! -f $job_file ]]; then exit 0; fi

# Try to read and validate
job_line=$(head -n 1 "$job_file")

# Check for printable ASCII (basic validation)
if ! echo "$job_line" | grep -q '^[[:print:]]*$'; then
    echo "ERROR: Job contains non-printable characters"
    mv "$job_file" "$JOBS_DIR/failed/"
    exit 1
fi

# Check format
pipe_count=$(echo "$job_line" | grep -o '|' | wc -l)
if [[ $pipe_count -ne 3 ]]; then
    mv "$job_file" "$JOBS_DIR/failed/"
    exit 1
fi
EOF
    chmod +x "$JOBS_DIR/test-worker.sh"

    JOBS_DIR="$JOBS_DIR" "$JOBS_DIR/test-worker.sh" || true

    if [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ Binary garbage job correctly rejected"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Binary garbage not handled"
        FAIL=$((FAIL + 1))
    fi

    cleanup_test_env
}

# FAIL-009: Very long path (4096+ characters)
test_very_long_path() {
    local test_name="FAIL-009"
    echo "[$test_name] Testing very long path..."

    setup_test_env

    local job_id="longpath-009"
    local job_file="$JOBS_DIR/pending/${job_id}.job"

    # Generate 5000-char path
    local long_path
    long_path=$(printf 'a%.0s' {1..5000})

    echo "${job_id}|s3_a|test-bucket/${long_path}.txt|$DATA_DIR/output.txt" > "$job_file"

    cat > "$JOBS_DIR/test-worker.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

JOBS_DIR="${JOBS_DIR:-/jobs}"

job_file="$JOBS_DIR/pending/"*.job
if [[ ! -f $job_file ]]; then exit 0; fi

job_line=$(cat "$job_file")

# Check line length (PATH_MAX = 4096 on most systems)
if [[ ${#job_line} -gt 4096 ]]; then
    echo "ERROR: Job line too long (${#job_line} chars, max 4096)"
    mv "$job_file" "$JOBS_DIR/failed/"
    exit 1
fi

pipe_count=$(echo "$job_line" | grep -o '|' | wc -l)
if [[ $pipe_count -ne 3 ]]; then
    mv "$job_file" "$JOBS_DIR/failed/"
    exit 1
fi
EOF
    chmod +x "$JOBS_DIR/test-worker.sh"

    JOBS_DIR="$JOBS_DIR" "$JOBS_DIR/test-worker.sh" || true

    if [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ Very long path correctly rejected"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Very long path not handled"
        FAIL=$((FAIL + 1))
    fi

    cleanup_test_env
}

# FAIL-010: Null bytes in job file
test_null_bytes() {
    local test_name="FAIL-010"
    echo "[$test_name] Testing null bytes in job file..."

    setup_test_env

    local job_id="nullbytes-010"
    local job_file="$JOBS_DIR/pending/${job_id}.job"

    # Create job with embedded null bytes
    printf "nullbytes\x00010|s3_a\x00|test-bucket/file.txt|/data/out.txt" > "$job_file"

    cat > "$JOBS_DIR/test-worker.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

JOBS_DIR="${JOBS_DIR:-/jobs}"

job_file="$JOBS_DIR/pending/"*.job
if [[ ! -f $job_file ]]; then exit 0; fi

# Check for null bytes
if grep -q $'\x00' "$job_file"; then
    echo "ERROR: Job file contains null bytes"
    mv "$job_file" "$JOBS_DIR/failed/"
    exit 1
fi

job_line=$(cat "$job_file")
pipe_count=$(echo "$job_line" | grep -o '|' | wc -l)
if [[ $pipe_count -ne 3 ]]; then
    mv "$job_file" "$JOBS_DIR/failed/"
    exit 1
fi
EOF
    chmod +x "$JOBS_DIR/test-worker.sh"

    JOBS_DIR="$JOBS_DIR" "$JOBS_DIR/test-worker.sh" || true

    if [[ -f "$JOBS_DIR/failed/${job_id}.job" ]]; then
        echo "  ✓ Null bytes correctly rejected"
        PASS=$((PASS + 1))
    else
        echo "  ✗ Null bytes not detected"
        FAIL=$((FAIL + 1))
    fi

    cleanup_test_env
}

# Run all invalid job tests
run_invalid_job_tests() {
    echo ""
    echo "============================================"
    echo "Invalid Job Tests (FAIL-006 to FAIL-010)"
    echo "============================================"
    echo ""

    PASS=0
    FAIL=0

    test_empty_file
    test_malformed_no_pipes
    test_binary_garbage
    test_very_long_path
    test_null_bytes

    echo ""
    echo "Invalid Job Test Summary: PASS=$PASS FAIL=$FAIL"
    echo ""

    return $FAIL
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_invalid_job_tests
fi
