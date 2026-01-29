#!/bin/bash
# run_all_chaos_tests.sh - Master chaos test runner
# Runs all chaos/failure tests (FAIL-001 to FAIL-022)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/helpers.sh"

# Test suite configuration
TOTAL_TESTS=22
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
    echo ""
}

run_test_group() {
    local test_script="$1"
    local test_name="$2"

    print_header "$test_name"

    if [[ ! -f "$test_script" ]]; then
        echo -e "${RED}ERROR: Test script not found: $test_script${NC}"
        return 1
    fi

    # Run test group
    if bash "$test_script"; then
        echo -e "${GREEN}✓ $test_name PASSED${NC}"
        return 0
    else
        echo -e "${RED}✗ $test_name FAILED${NC}"
        return 1
    fi
}

# Main test execution
main() {
    print_header "S3SWEEP CHAOS TEST SUITE"
    echo "Running all failure scenario tests (FAIL-001 to FAIL-022)"
    echo ""

    # Initialize test environment
    setup_global_test_env

    # Track failures
    local failed_groups=()

    # Run each test group
    echo "Starting chaos tests..."
    echo ""

    # Network Partition Tests (FAIL-001 to FAIL-005)
    if run_test_group "$SCRIPT_DIR/network_partition.sh" "Network Partition Tests"; then
        TESTS_PASSED=$((TESTS_PASSED + 5))
    else
        TESTS_FAILED=$((TESTS_FAILED + 5))
        failed_groups+=("Network Partition")
    fi
    TESTS_RUN=$((TESTS_RUN + 5))

    # Invalid Job Tests (FAIL-006 to FAIL-010)
    if run_test_group "$SCRIPT_DIR/invalid_jobs.sh" "Invalid Job Tests"; then
        TESTS_PASSED=$((TESTS_PASSED + 5))
    else
        TESTS_FAILED=$((TESTS_FAILED + 5))
        failed_groups+=("Invalid Jobs")
    fi
    TESTS_RUN=$((TESTS_RUN + 5))

    # Disk Full Tests (FAIL-011 to FAIL-014)
    if run_test_group "$SCRIPT_DIR/disk_full.sh" "Disk/Permission Tests"; then
        TESTS_PASSED=$((TESTS_PASSED + 4))
    else
        TESTS_FAILED=$((TESTS_FAILED + 4))
        failed_groups+=("Disk/Permission")
    fi
    TESTS_RUN=$((TESTS_RUN + 4))

    # Crash Tests (FAIL-015 to FAIL-018)
    if run_test_group "$SCRIPT_DIR/crash.sh" "Crash Scenario Tests"; then
        TESTS_PASSED=$((TESTS_PASSED + 4))
    else
        TESTS_FAILED=$((TESTS_FAILED + 4))
        failed_groups+=("Crash Scenarios")
    fi
    TESTS_RUN=$((TESTS_RUN + 4))

    # Edge Case Tests (FAIL-019 to FAIL-022)
    if run_test_group "$SCRIPT_DIR/edge_cases.sh" "Edge Case Tests"; then
        TESTS_PASSED=$((TESTS_PASSED + 4))
    else
        TESTS_FAILED=$((TESTS_FAILED + 4))
        failed_groups+=("Edge Cases")
    fi
    TESTS_RUN=$((TESTS_RUN + 4))

    # Final summary
    print_header "CHAOS TEST SUITE SUMMARY"

    echo "Total Tests:   $TESTS_RUN / $TOTAL_TESTS"
    echo -e "Passed:        ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed:        ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ ALL CHAOS TESTS PASSED${NC}"
        echo ""
        cleanup_global_test_env
        return 0
    else
        echo -e "${RED}✗ SOME TESTS FAILED${NC}"
        echo ""
        echo "Failed test groups:"
        for group in "${failed_groups[@]}"; do
            echo -e "  ${RED}- $group${NC}"
        done
        echo ""
        cleanup_global_test_env
        return 1
    fi
}

# Cleanup on exit
trap cleanup_global_test_env EXIT

# Run main
main "$@"
