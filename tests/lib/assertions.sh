#!/usr/bin/env bash
set -euo pipefail

# Test Assertion Functions for s3sweep
# Provides assertion utilities for validating test conditions

# Color codes for output
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_RESET='\033[0m'

# Global counters
ASSERTION_COUNT=0
ASSERTION_FAILED=0

#######################################
# Internal function to record assertion result
# Arguments:
#   $1 - Success (0) or failure (1)
#   $2 - Assertion description
# Returns:
#   Same as input ($1)
#######################################
_record_assertion() {
    local result=$1
    local description="$2"

    ((ASSERTION_COUNT++))

    if [[ $result -eq 0 ]]; then
        echo -e "${COLOR_GREEN}[PASS]${COLOR_RESET} ${description}"
        return 0
    else
        echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} ${description}"
        ((ASSERTION_FAILED++))
        return 1
    fi
}

#######################################
# Assert that a file exists
# Arguments:
#   $1 - File path
# Returns:
#   0 if file exists, 1 otherwise
#######################################
assert_file_exists() {
    local file="$1"

    if [[ -f "${file}" ]]; then
        _record_assertion 0 "File exists: ${file}"
        return 0
    else
        _record_assertion 1 "File should exist but not found: ${file}"
        return 1
    fi
}

#######################################
# Assert that a file does not exist
# Arguments:
#   $1 - File path
# Returns:
#   0 if file does not exist, 1 otherwise
#######################################
assert_file_not_exists() {
    local file="$1"

    if [[ ! -f "${file}" ]]; then
        _record_assertion 0 "File does not exist: ${file}"
        return 0
    else
        _record_assertion 1 "File should not exist but found: ${file}"
        return 1
    fi
}

#######################################
# Assert that a file exists in specified directory
# Arguments:
#   $1 - Filename
#   $2 - Directory path
# Returns:
#   0 if file exists in directory, 1 otherwise
#######################################
assert_file_in_dir() {
    local filename="$1"
    local dir="$2"
    local filepath="${dir}/${filename}"

    if [[ -f "${filepath}" ]]; then
        _record_assertion 0 "File '${filename}' found in ${dir}"
        return 0
    else
        _record_assertion 1 "File '${filename}' not found in ${dir}"
        return 1
    fi
}

#######################################
# Assert that a job succeeded (file in done/)
# Arguments:
#   $1 - Job name (without .job extension)
# Globals:
#   TEST_JOBS_DIR
# Returns:
#   0 if job succeeded, 1 otherwise
#######################################
assert_job_succeeded() {
    local job_name="$1"
    local done_file="${TEST_JOBS_DIR}/done/${job_name}.job"

    if [[ -f "${done_file}" ]]; then
        _record_assertion 0 "Job succeeded: ${job_name}"
        return 0
    else
        _record_assertion 1 "Job should have succeeded but not in done/: ${job_name}"
        return 1
    fi
}

#######################################
# Assert that a job failed (file in failed/)
# Arguments:
#   $1 - Job name (without .job extension)
# Globals:
#   TEST_JOBS_DIR
# Returns:
#   0 if job failed, 1 otherwise
#######################################
assert_job_failed() {
    local job_name="$1"
    local failed_file="${TEST_JOBS_DIR}/failed/${job_name}.job"

    if [[ -f "${failed_file}" ]]; then
        _record_assertion 0 "Job failed as expected: ${job_name}"
        return 0
    else
        _record_assertion 1 "Job should have failed but not in failed/: ${job_name}"
        return 1
    fi
}

#######################################
# Assert that log contains pattern
# Arguments:
#   $1 - Pattern to search (grep compatible)
# Globals:
#   WORKER_LOG
# Returns:
#   0 if pattern found, 1 otherwise
#######################################
assert_log_contains() {
    local pattern="$1"

    if [[ ! -f "${WORKER_LOG}" ]]; then
        _record_assertion 1 "Worker log not found: ${WORKER_LOG}"
        return 1
    fi

    if grep -q "${pattern}" "${WORKER_LOG}"; then
        _record_assertion 0 "Log contains pattern: ${pattern}"
        return 0
    else
        _record_assertion 1 "Log does not contain pattern: ${pattern}"
        echo "  Log contents:"
        cat "${WORKER_LOG}" | sed 's/^/    /'
        return 1
    fi
}

#######################################
# Assert that two files have matching checksums
# Arguments:
#   $1 - First file path
#   $2 - Second file path
# Returns:
#   0 if checksums match, 1 otherwise
#######################################
assert_checksum_match() {
    local file1="$1"
    local file2="$2"

    if [[ ! -f "${file1}" ]]; then
        _record_assertion 1 "First file not found: ${file1}"
        return 1
    fi

    if [[ ! -f "${file2}" ]]; then
        _record_assertion 1 "Second file not found: ${file2}"
        return 1
    fi

    local checksum1
    local checksum2

    # Use md5 on macOS, md5sum on Linux
    if command -v md5sum &> /dev/null; then
        checksum1=$(md5sum "${file1}" | awk '{print $1}')
        checksum2=$(md5sum "${file2}" | awk '{print $1}')
    elif command -v md5 &> /dev/null; then
        checksum1=$(md5 -q "${file1}")
        checksum2=$(md5 -q "${file2}")
    else
        _record_assertion 1 "No checksum utility found (md5sum or md5)"
        return 1
    fi

    if [[ "${checksum1}" == "${checksum2}" ]]; then
        _record_assertion 0 "Checksums match: ${checksum1}"
        return 0
    else
        _record_assertion 1 "Checksums do not match: ${checksum1} vs ${checksum2}"
        return 1
    fi
}

#######################################
# Assert that JSON field has expected value
# Arguments:
#   $1 - JSON string or file path
#   $2 - Field path (jq compatible, e.g., ".status" or ".data.count")
#   $3 - Expected value
# Returns:
#   0 if field matches expected value, 1 otherwise
#######################################
assert_json_field() {
    local json_input="$1"
    local field="$2"
    local expected="$3"

    if ! command -v jq &> /dev/null; then
        _record_assertion 1 "jq not installed, cannot validate JSON"
        return 1
    fi

    local actual
    if [[ -f "${json_input}" ]]; then
        actual=$(jq -r "${field}" "${json_input}" 2>/dev/null || echo "PARSE_ERROR")
    else
        actual=$(echo "${json_input}" | jq -r "${field}" 2>/dev/null || echo "PARSE_ERROR")
    fi

    if [[ "${actual}" == "PARSE_ERROR" ]]; then
        _record_assertion 1 "Failed to parse JSON or field not found: ${field}"
        return 1
    fi

    if [[ "${actual}" == "${expected}" ]]; then
        _record_assertion 0 "JSON field ${field} = '${expected}'"
        return 0
    else
        _record_assertion 1 "JSON field ${field} expected '${expected}', got '${actual}'"
        return 1
    fi
}

#######################################
# Assert that actual value is greater than expected
# Arguments:
#   $1 - Actual value
#   $2 - Expected minimum value
# Returns:
#   0 if actual > expected, 1 otherwise
#######################################
assert_greater_than() {
    local actual="$1"
    local expected="$2"

    if [[ ! "${actual}" =~ ^-?[0-9]+\.?[0-9]*$ ]] || [[ ! "${expected}" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        _record_assertion 1 "Non-numeric values: actual='${actual}', expected='${expected}'"
        return 1
    fi

    if (( $(echo "${actual} > ${expected}" | bc -l) )); then
        _record_assertion 0 "${actual} > ${expected}"
        return 0
    else
        _record_assertion 1 "${actual} should be > ${expected}"
        return 1
    fi
}

#######################################
# Assert that two values are equal
# Arguments:
#   $1 - Actual value
#   $2 - Expected value
# Returns:
#   0 if equal, 1 otherwise
#######################################
assert_equals() {
    local actual="$1"
    local expected="$2"

    if [[ "${actual}" == "${expected}" ]]; then
        _record_assertion 0 "'${actual}' == '${expected}'"
        return 0
    else
        _record_assertion 1 "Expected '${expected}', got '${actual}'"
        return 1
    fi
}

#######################################
# Assert that a string contains a substring
# Arguments:
#   $1 - Haystack string
#   $2 - Needle substring
# Returns:
#   0 if substring found, 1 otherwise
#######################################
assert_contains() {
    local haystack="$1"
    local needle="$2"

    if [[ "${haystack}" == *"${needle}"* ]]; then
        _record_assertion 0 "String contains: '${needle}'"
        return 0
    else
        _record_assertion 1 "String does not contain: '${needle}'"
        echo "  Haystack: ${haystack}"
        return 1
    fi
}

#######################################
# Assert that a directory exists
# Arguments:
#   $1 - Directory path
# Returns:
#   0 if directory exists, 1 otherwise
#######################################
assert_dir_exists() {
    local dir="$1"

    if [[ -d "${dir}" ]]; then
        _record_assertion 0 "Directory exists: ${dir}"
        return 0
    else
        _record_assertion 1 "Directory should exist but not found: ${dir}"
        return 1
    fi
}

#######################################
# Assert that a directory is empty
# Arguments:
#   $1 - Directory path
# Returns:
#   0 if directory is empty, 1 otherwise
#######################################
assert_dir_empty() {
    local dir="$1"

    if [[ ! -d "${dir}" ]]; then
        _record_assertion 1 "Directory not found: ${dir}"
        return 1
    fi

    local file_count
    file_count=$(find "${dir}" -type f | wc -l | tr -d ' ')

    if [[ "${file_count}" -eq 0 ]]; then
        _record_assertion 0 "Directory is empty: ${dir}"
        return 0
    else
        _record_assertion 1 "Directory should be empty but contains ${file_count} files: ${dir}"
        return 1
    fi
}

#######################################
# Print assertion summary
# Globals:
#   ASSERTION_COUNT
#   ASSERTION_FAILED
# Returns:
#   0 if all assertions passed, 1 if any failed
#######################################
print_assertion_summary() {
    local passed=$((ASSERTION_COUNT - ASSERTION_FAILED))

    echo ""
    echo "========================================"
    if [[ ${ASSERTION_FAILED} -eq 0 ]]; then
        echo -e "${COLOR_GREEN}All ${ASSERTION_COUNT} assertions passed!${COLOR_RESET}"
        echo "========================================"
        return 0
    else
        echo -e "${COLOR_RED}${ASSERTION_FAILED}/${ASSERTION_COUNT} assertions failed${COLOR_RESET}"
        echo "========================================"
        return 1
    fi
}

#######################################
# Reset assertion counters
# Globals:
#   ASSERTION_COUNT
#   ASSERTION_FAILED
# Returns:
#   0 on success
#######################################
reset_assertions() {
    ASSERTION_COUNT=0
    ASSERTION_FAILED=0
}
