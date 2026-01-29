#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Color codes
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_RESET='\033[0m'

# Configuration
readonly MINIO_ENDPOINT="http://localhost:9000"
readonly SKIP_SETUP="${SKIP_SETUP:-false}"
readonly SKIP_CLEANUP="${SKIP_CLEANUP:-false}"

#######################################
# Print banner
#######################################
print_banner() {
    echo ""
    echo -e "${COLOR_BLUE}========================================${COLOR_RESET}"
    echo -e "${COLOR_BLUE}    s3sweep Integration Test Suite    ${COLOR_RESET}"
    echo -e "${COLOR_BLUE}========================================${COLOR_RESET}"
    echo ""
}

#######################################
# Check prerequisites
#######################################
check_prerequisites() {
    echo -e "${COLOR_YELLOW}[CHECK]${COLOR_RESET} Verifying prerequisites..."

    local missing=0

    # Check Docker
    if ! command -v docker &> /dev/null; then
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} docker not found"
        ((missing++))
    fi

    # Check Docker Compose
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} docker-compose not found"
        ((missing++))
    fi

    # Check rclone
    if ! command -v rclone &> /dev/null; then
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} rclone not found (install: brew install rclone)"
        ((missing++))
    fi

    # Check MinIO client
    if ! command -v mc &> /dev/null; then
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} mc not found (install: brew install minio/stable/mc)"
        ((missing++))
    fi

    # Check jq
    if ! command -v jq &> /dev/null; then
        echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} jq not found (optional, for JSON parsing)"
    fi

    if [ $missing -gt 0 ]; then
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $missing prerequisite(s) missing"
        return 1
    fi

    echo -e "${COLOR_GREEN}[CHECK]${COLOR_RESET} All prerequisites satisfied"
    return 0
}

#######################################
# Start test environment
#######################################
start_environment() {
    echo -e "${COLOR_YELLOW}[SETUP]${COLOR_RESET} Starting test environment..."

    cd "${SCRIPT_DIR}"

    # Start Docker Compose
    if docker compose version &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi

    # Wait for services to be healthy
    echo -e "${COLOR_YELLOW}[SETUP]${COLOR_RESET} Waiting for MinIO to be ready..."
    local max_attempts=30
    for i in $(seq 1 ${max_attempts}); do
        if curl -sf "${MINIO_ENDPOINT}/minio/health/live" > /dev/null 2>&1; then
            echo -e "${COLOR_GREEN}[SETUP]${COLOR_RESET} MinIO is ready"
            return 0
        fi
        sleep 1
    done

    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} MinIO failed to start"
    return 1
}

#######################################
# Setup test data
#######################################
setup_test_data() {
    echo -e "${COLOR_YELLOW}[SETUP]${COLOR_RESET} Setting up test data..."

    cd "${SCRIPT_DIR}"
    ./setup.sh

    if [ $? -eq 0 ]; then
        echo -e "${COLOR_GREEN}[SETUP]${COLOR_RESET} Test data ready"
        return 0
    else
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} Failed to setup test data"
        return 1
    fi
}

#######################################
# Run test suite
#######################################
run_test_suite() {
    local test_script="$1"
    local test_name="$2"

    echo ""
    echo -e "${COLOR_BLUE}========================================${COLOR_RESET}"
    echo -e "${COLOR_BLUE}Running: ${test_name}${COLOR_RESET}"
    echo -e "${COLOR_BLUE}========================================${COLOR_RESET}"

    cd "${SCRIPT_DIR}"

    if [ ! -f "${test_script}" ]; then
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} Test script not found: ${test_script}"
        return 1
    fi

    # Run test and capture result
    local start_time=$(date +%s)
    local result=0

    bash "${test_script}" || result=$?

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ $result -eq 0 ]; then
        echo -e "${COLOR_GREEN}[PASS]${COLOR_RESET} ${test_name} (${duration}s)"
        return 0
    else
        echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} ${test_name} (${duration}s)"
        return 1
    fi
}

#######################################
# Cleanup environment
#######################################
cleanup_environment() {
    echo ""
    echo -e "${COLOR_YELLOW}[CLEANUP]${COLOR_RESET} Cleaning up test environment..."

    cd "${SCRIPT_DIR}"

    # Remove test data
    if [ -d "testdata" ]; then
        rm -rf testdata
        echo -e "${COLOR_GREEN}[CLEANUP]${COLOR_RESET} Removed test data"
    fi

    # Stop Docker Compose
    if docker compose version &> /dev/null; then
        docker compose down -v
    else
        docker-compose down -v
    fi

    echo -e "${COLOR_GREEN}[CLEANUP]${COLOR_RESET} Environment cleaned up"
}

#######################################
# Print test summary
#######################################
print_summary() {
    local total=$1
    local passed=$2
    local failed=$3
    local duration=$4

    echo ""
    echo -e "${COLOR_BLUE}========================================${COLOR_RESET}"
    echo -e "${COLOR_BLUE}          TEST SUMMARY                 ${COLOR_RESET}"
    echo -e "${COLOR_BLUE}========================================${COLOR_RESET}"
    echo "Total Test Suites: ${total}"
    echo -e "${COLOR_GREEN}Passed: ${passed}${COLOR_RESET}"
    echo -e "${COLOR_RED}Failed: ${failed}${COLOR_RESET}"
    echo "Total Duration: ${duration}s"
    echo -e "${COLOR_BLUE}========================================${COLOR_RESET}"
    echo ""

    if [ $failed -eq 0 ]; then
        echo -e "${COLOR_GREEN}✓ All test suites passed!${COLOR_RESET}"
        return 0
    else
        echo -e "${COLOR_RED}✗ ${failed} test suite(s) failed${COLOR_RESET}"
        return 1
    fi
}

#######################################
# Main execution
#######################################
main() {
    local start_time=$(date +%s)
    local total_suites=0
    local passed_suites=0
    local failed_suites=0

    print_banner

    # Check prerequisites
    if ! check_prerequisites; then
        exit 1
    fi

    # Setup environment unless skipped
    if [ "${SKIP_SETUP}" != "true" ]; then
        if ! start_environment; then
            echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} Failed to start environment"
            exit 1
        fi

        if ! setup_test_data; then
            echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} Failed to setup test data"
            cleanup_environment
            exit 1
        fi
    else
        echo -e "${COLOR_YELLOW}[SKIP]${COLOR_RESET} Skipping environment setup (SKIP_SETUP=true)"
    fi

    # Run E2E tests
    ((total_suites++))
    if run_test_suite "test_e2e.sh" "End-to-End Tests"; then
        ((passed_suites++))
    else
        ((failed_suites++))
    fi

    # Run Multi-Worker tests
    ((total_suites++))
    if run_test_suite "test_multiworker.sh" "Multi-Worker Tests"; then
        ((passed_suites++))
    else
        ((failed_suites++))
    fi

    # Cleanup unless skipped
    if [ "${SKIP_CLEANUP}" != "true" ]; then
        cleanup_environment
    else
        echo -e "${COLOR_YELLOW}[SKIP]${COLOR_RESET} Skipping cleanup (SKIP_CLEANUP=true)"
    fi

    # Calculate total duration
    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))

    # Print summary
    if ! print_summary ${total_suites} ${passed_suites} ${failed_suites} ${total_duration}; then
        exit 1
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-setup)
            SKIP_SETUP=true
            shift
            ;;
        --skip-cleanup)
            SKIP_CLEANUP=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-setup     Skip environment setup (use existing)"
            echo "  --skip-cleanup   Skip cleanup after tests"
            echo "  --help           Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  SKIP_SETUP       Set to 'true' to skip setup"
            echo "  SKIP_CLEANUP     Set to 'true' to skip cleanup"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Run main
main
