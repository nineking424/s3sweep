#!/usr/bin/env bash
# Master test runner for all s3sweep Kubernetes tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helpers.sh"

# Test configuration
STOP_ON_FAILURE="${STOP_ON_FAILURE:-0}"
VERBOSE="${VERBOSE:-0}"
SKIP_SETUP="${SKIP_SETUP:-0}"

# Test suites to run
TEST_SUITES=(
    "test_scaling.sh:Scaling Tests"
    "test_probes.sh:Health Probe Tests"
    "test_orphan_recovery.sh:Orphan Recovery Tests"
    "test_termination.sh:Termination Tests"
    "test_volumes.sh:Volume Tests"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_banner() {
    echo
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                            ║${NC}"
    echo -e "${CYAN}║             S3Sweep Kubernetes Test Suite                 ║${NC}"
    echo -e "${CYAN}║                                                            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
}

print_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Run all Kubernetes tests for s3sweep.

OPTIONS:
    --skip-setup        Skip environment setup (use existing cluster)
    --stop-on-failure   Stop running tests after first failure
    --verbose           Enable verbose output
    --suite <name>      Run specific test suite only
    --list              List available test suites
    -h, --help          Show this help message

EXAMPLES:
    # Run all tests with setup
    $0

    # Run all tests on existing cluster
    $0 --skip-setup

    # Run specific suite
    $0 --suite test_scaling.sh

    # Stop on first failure with verbose output
    $0 --stop-on-failure --verbose

ENVIRONMENT VARIABLES:
    STOP_ON_FAILURE     Set to 1 to stop on first failure
    VERBOSE             Set to 1 for verbose output
    SKIP_SETUP          Set to 1 to skip setup
    CLUSTER_NAME        Kind cluster name (default: s3sweep-test)

EOF
}

list_suites() {
    echo "Available test suites:"
    echo
    for suite in "${TEST_SUITES[@]}"; do
        local script="${suite%%:*}"
        local description="${suite##*:}"
        echo -e "  ${BLUE}${script}${NC} - ${description}"
    done
    echo
}

check_environment() {
    log_info "Checking test environment..."

    # Check if kubectl is available
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi

    # Check cluster connectivity
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        log_error "Run './setup.sh' to create test cluster"
        exit 1
    fi

    # Check if test namespace exists
    if ! kubectl get namespace s3sweep-test &>/dev/null; then
        log_error "Test namespace 's3sweep-test' not found"
        log_error "Run './setup.sh' to create test environment"
        exit 1
    fi

    log_success "Environment check passed"
}

run_setup() {
    log_info "Running environment setup..."

    if [ ! -f "${SCRIPT_DIR}/setup.sh" ]; then
        log_error "setup.sh not found"
        exit 1
    fi

    if bash "${SCRIPT_DIR}/setup.sh"; then
        log_success "Setup completed"
    else
        log_error "Setup failed"
        exit 1
    fi
}

run_test_suite() {
    local test_script=$1
    local description=$2

    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Running: ${description}${NC}"
    echo -e "${BLUE}  Script: ${test_script}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo

    local script_path="${SCRIPT_DIR}/${test_script}"

    if [ ! -f "$script_path" ]; then
        log_error "Test script not found: $script_path"
        return 1
    fi

    if [ ! -x "$script_path" ]; then
        chmod +x "$script_path"
    fi

    # Run test suite
    local start_time=$(date +%s)
    local exit_code=0

    if [ "$VERBOSE" = "1" ]; then
        bash "$script_path" || exit_code=$?
    else
        bash "$script_path" 2>&1 | grep -E "(PASS|FAIL|ERROR|Test Results)" || exit_code=$?
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo
    if [ $exit_code -eq 0 ]; then
        log_success "✓ ${description} completed in ${duration}s"
        return 0
    else
        log_error "✗ ${description} failed after ${duration}s"
        return 1
    fi
}

run_all_suites() {
    local total=0
    local passed=0
    local failed=0
    local failed_suites=()

    for suite in "${TEST_SUITES[@]}"; do
        local script="${suite%%:*}"
        local description="${suite##*:}"

        total=$((total + 1))

        if run_test_suite "$script" "$description"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            failed_suites+=("$description")

            if [ "$STOP_ON_FAILURE" = "1" ]; then
                log_error "Stopping on first failure"
                break
            fi
        fi
    done

    # Print summary
    echo
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    Final Test Summary                     ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo "Total Suites:  $total"
    echo -e "Passed:        ${GREEN}${passed}${NC}"
    echo -e "Failed:        ${RED}${failed}${NC}"
    echo

    if [ ${#failed_suites[@]} -gt 0 ]; then
        echo -e "${RED}Failed Test Suites:${NC}"
        for suite in "${failed_suites[@]}"; do
            echo -e "  ${RED}✗${NC} $suite"
        done
        echo
        return 1
    else
        echo -e "${GREEN}All test suites passed! 🎉${NC}"
        echo
        return 0
    fi
}

# Parse command line arguments
SPECIFIC_SUITE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-setup)
            SKIP_SETUP=1
            shift
            ;;
        --stop-on-failure)
            STOP_ON_FAILURE=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --suite)
            SPECIFIC_SUITE="$2"
            shift 2
            ;;
        --list)
            list_suites
            exit 0
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Main execution
main() {
    print_banner

    # Setup phase
    if [ "$SKIP_SETUP" = "1" ]; then
        log_info "Skipping setup (--skip-setup specified)"
        check_environment
    else
        run_setup
    fi

    # Test execution phase
    if [ -n "$SPECIFIC_SUITE" ]; then
        # Run specific suite
        log_info "Running specific suite: $SPECIFIC_SUITE"

        local found=0
        for suite in "${TEST_SUITES[@]}"; do
            local script="${suite%%:*}"
            local description="${suite##*:}"

            if [ "$script" = "$SPECIFIC_SUITE" ]; then
                found=1
                run_test_suite "$script" "$description"
                exit $?
            fi
        done

        if [ $found -eq 0 ]; then
            log_error "Test suite not found: $SPECIFIC_SUITE"
            list_suites
            exit 1
        fi
    else
        # Run all suites
        run_all_suites
        exit $?
    fi
}

# Run main
main "$@"
