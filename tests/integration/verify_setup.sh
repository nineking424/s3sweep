#!/bin/bash
set -euo pipefail

# Color codes
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKS_PASSED=0
CHECKS_FAILED=0

check_file() {
    local file="$1"
    local description="$2"

    if [ -f "${SCRIPT_DIR}/${file}" ]; then
        echo -e "${COLOR_GREEN}✓${COLOR_RESET} ${description}: ${file}"
        ((CHECKS_PASSED++))
        return 0
    else
        echo -e "${COLOR_RED}✗${COLOR_RESET} ${description}: ${file} (MISSING)"
        ((CHECKS_FAILED++))
        return 1
    fi
}

check_executable() {
    local file="$1"
    local description="$2"

    if [ -x "${SCRIPT_DIR}/${file}" ]; then
        echo -e "${COLOR_GREEN}✓${COLOR_RESET} ${description}: ${file} (executable)"
        ((CHECKS_PASSED++))
        return 0
    else
        echo -e "${COLOR_RED}✗${COLOR_RESET} ${description}: ${file} (not executable)"
        ((CHECKS_FAILED++))
        return 1
    fi
}

check_command() {
    local cmd="$1"
    local description="$2"
    local install_hint="$3"

    if command -v "${cmd}" &> /dev/null; then
        echo -e "${COLOR_GREEN}✓${COLOR_RESET} ${description}: ${cmd}"
        ((CHECKS_PASSED++))
        return 0
    else
        echo -e "${COLOR_RED}✗${COLOR_RESET} ${description}: ${cmd} (install: ${install_hint})"
        ((CHECKS_FAILED++))
        return 1
    fi
}

echo "========================================"
echo "Integration Test Setup Verification"
echo "========================================"
echo ""

echo "1. Checking Core Files"
echo "----------------------"
check_file "docker-compose.yaml" "Docker Compose config"
check_file "setup.sh" "Setup script"
check_file "test_e2e.sh" "E2E tests"
check_file "test_multiworker.sh" "Multi-worker tests"
check_file "run_all_tests.sh" "Master test runner"
check_file "Makefile" "Makefile"
check_file "README.md" "Documentation"
check_file "SUMMARY.md" "Summary"
echo ""

echo "2. Checking Script Permissions"
echo "-------------------------------"
check_executable "setup.sh" "Setup script"
check_executable "test_e2e.sh" "E2E tests"
check_executable "test_multiworker.sh" "Multi-worker tests"
check_executable "run_all_tests.sh" "Master runner"
echo ""

echo "3. Checking Test Libraries"
echo "--------------------------"
check_file "../lib/helpers.sh" "Test helpers"
check_file "../lib/assertions.sh" "Test assertions"

if [ -f "../lib/helpers.sh" ]; then
    if [ -x "../lib/helpers.sh" ]; then
        echo -e "${COLOR_GREEN}✓${COLOR_RESET} helpers.sh is executable"
        ((CHECKS_PASSED++))
    else
        echo -e "${COLOR_YELLOW}!${COLOR_RESET} helpers.sh should be executable"
    fi
fi

if [ -f "../lib/assertions.sh" ]; then
    if [ -x "../lib/assertions.sh" ]; then
        echo -e "${COLOR_GREEN}✓${COLOR_RESET} assertions.sh is executable"
        ((CHECKS_PASSED++))
    else
        echo -e "${COLOR_YELLOW}!${COLOR_RESET} assertions.sh should be executable"
    fi
fi
echo ""

echo "4. Checking Prerequisites"
echo "-------------------------"
check_command "docker" "Docker" "https://docs.docker.com/get-docker/"
check_command "rclone" "rclone" "brew install rclone"
check_command "mc" "MinIO client" "brew install minio/stable/mc"

# Optional but recommended
if command -v jq &> /dev/null; then
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} Optional: jq (for JSON parsing)"
    ((CHECKS_PASSED++))
else
    echo -e "${COLOR_YELLOW}!${COLOR_RESET} Optional: jq (install: brew install jq)"
fi

# Check Docker Compose command
if docker compose version &> /dev/null; then
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} Docker Compose: docker compose"
    ((CHECKS_PASSED++))
elif command -v docker-compose &> /dev/null; then
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} Docker Compose: docker-compose"
    ((CHECKS_PASSED++))
else
    echo -e "${COLOR_RED}✗${COLOR_RESET} Docker Compose not found"
    ((CHECKS_FAILED++))
fi
echo ""

echo "5. Checking Documentation"
echo "-------------------------"
check_file "README.md" "Integration README"
check_file "../TESTING.md" "Testing guide"
check_file "SUMMARY.md" "Implementation summary"
echo ""

echo "6. Checking CI/CD"
echo "-----------------"
if [ -f "../../.github/workflows/integration-tests.yml" ]; then
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} GitHub Actions workflow exists"
    ((CHECKS_PASSED++))
else
    echo -e "${COLOR_RED}✗${COLOR_RESET} GitHub Actions workflow missing"
    ((CHECKS_FAILED++))
fi
echo ""

echo "7. Test Count Verification"
echo "--------------------------"

# Count tests in test_e2e.sh
if [ -f "test_e2e.sh" ]; then
    local e2e_count=$(grep -c "^test_.*() {" test_e2e.sh || echo 0)
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} E2E tests found: ${e2e_count}"
    ((CHECKS_PASSED++))
fi

# Count tests in test_multiworker.sh
if [ -f "test_multiworker.sh" ]; then
    local multi_count=$(grep -c "^test_.*() {" test_multiworker.sh || echo 0)
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} Multi-worker tests found: ${multi_count}"
    ((CHECKS_PASSED++))
fi
echo ""

echo "========================================"
echo "Summary"
echo "========================================"
echo "Checks Passed: ${CHECKS_PASSED}"
echo "Checks Failed: ${CHECKS_FAILED}"
echo ""

if [ ${CHECKS_FAILED} -eq 0 ]; then
    echo -e "${COLOR_GREEN}✓ All checks passed!${COLOR_RESET}"
    echo ""
    echo "Next steps:"
    echo "  1. Start test environment:  make setup"
    echo "  2. Run all tests:          make test"
    echo "  3. Or use:                 ./run_all_tests.sh"
    echo ""
    exit 0
else
    echo -e "${COLOR_RED}✗ ${CHECKS_FAILED} check(s) failed${COLOR_RESET}"
    echo ""
    echo "Please fix the issues above before running tests."
    exit 1
fi
