#!/usr/bin/env bash
# Test helper functions for s3sweep Kubernetes tests

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test state
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0
CURRENT_TEST=""

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# Test lifecycle functions
test_suite_start() {
    local suite_name=$1
    echo
    echo "=========================================="
    echo "$suite_name"
    echo "=========================================="
    echo
    TEST_COUNT=0
    TEST_PASSED=0
    TEST_FAILED=0
}

test_start() {
    local test_name=$1
    CURRENT_TEST="$test_name"
    TEST_COUNT=$((TEST_COUNT + 1))
    echo
    echo "----------------------------------------"
    log_info "Running: $test_name"
    echo "----------------------------------------"
}

test_pass() {
    TEST_PASSED=$((TEST_PASSED + 1))
    log_success "✓ $CURRENT_TEST"
}

test_fail() {
    local message=${1:-"Test failed"}
    TEST_FAILED=$((TEST_FAILED + 1))
    log_error "✗ $CURRENT_TEST"
    log_error "  $message"

    # Print test context if available
    if [ -n "${NAMESPACE:-}" ]; then
        log_error "  Namespace: $NAMESPACE"
    fi

    # Optionally exit on first failure (set FAIL_FAST=1)
    if [ "${FAIL_FAST:-0}" = "1" ]; then
        exit 1
    fi
}

test_suite_end() {
    echo
    echo "=========================================="
    echo "Test Results"
    echo "=========================================="
    echo "Total:  $TEST_COUNT"
    echo -e "Passed: ${GREEN}$TEST_PASSED${NC}"
    echo -e "Failed: ${RED}$TEST_FAILED${NC}"
    echo "=========================================="
    echo

    if [ "$TEST_FAILED" -gt 0 ]; then
        exit 1
    fi
}

# Assertion functions
assert_equals() {
    local expected=$1
    local actual=$2
    local message=${3:-"Values should be equal"}

    if [ "$expected" != "$actual" ]; then
        test_fail "$message (expected: '$expected', actual: '$actual')"
        return 1
    fi
    return 0
}

assert_not_equals() {
    local expected=$1
    local actual=$2
    local message=${3:-"Values should not be equal"}

    if [ "$expected" = "$actual" ]; then
        test_fail "$message (both are: '$expected')"
        return 1
    fi
    return 0
}

assert_true() {
    local condition=$1
    local message=${2:-"Condition should be true"}

    if ! eval "$condition"; then
        test_fail "$message (condition: '$condition')"
        return 1
    fi
    return 0
}

assert_false() {
    local condition=$1
    local message=${2:-"Condition should be false"}

    if eval "$condition"; then
        test_fail "$message (condition: '$condition')"
        return 1
    fi
    return 0
}

assert_not_empty() {
    local value=$1
    local message=${2:-"Value should not be empty"}

    if [ -z "$value" ]; then
        test_fail "$message"
        return 1
    fi
    return 0
}

assert_empty() {
    local value=$1
    local message=${2:-"Value should be empty"}

    if [ -n "$value" ]; then
        test_fail "$message (value: '$value')"
        return 1
    fi
    return 0
}

assert_contains() {
    local haystack=$1
    local needle=$2
    local message=${3:-"String should contain substring"}

    if [[ ! "$haystack" =~ $needle ]]; then
        test_fail "$message (looking for '$needle' in '$haystack')"
        return 1
    fi
    return 0
}

assert_file_exists() {
    local pod=$1
    local namespace=$2
    local file=$3
    local message=${4:-"File should exist"}

    local exists=$(kubectl exec "$pod" -n "$namespace" -- test -f "$file" && echo "true" || echo "false")
    if [ "$exists" != "true" ]; then
        test_fail "$message (file: $file, pod: $pod)"
        return 1
    fi
    return 0
}

# Kubernetes helper functions
wait_for_ready_pods() {
    local expected_count=$1
    local namespace=${2:-${NAMESPACE}}
    local max_wait=${3:-120}

    log_info "Waiting for $expected_count ready pod(s)..."

    for i in $(seq 1 $max_wait); do
        local ready_count=$(kubectl get pods -n "$namespace" -l app=rclone-worker \
            --field-selector=status.phase=Running \
            -o json 2>/dev/null | \
            jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length')

        if [ "$ready_count" -eq "$expected_count" ]; then
            log_success "$expected_count pod(s) ready"
            return 0
        fi

        if [ $((i % 10)) -eq 0 ]; then
            log_info "Still waiting... ($ready_count/$expected_count ready)"
        fi

        sleep 1
    done

    log_error "Timeout waiting for pods to be ready"
    kubectl get pods -n "$namespace" -l app=rclone-worker
    return 1
}

wait_for_pod_termination() {
    local pod_name=$1
    local namespace=${2:-${NAMESPACE}}
    local max_wait=${3:-60}

    log_info "Waiting for pod $pod_name to terminate..."

    for i in $(seq 1 $max_wait); do
        if ! kubectl get pod "$pod_name" -n "$namespace" &>/dev/null; then
            log_success "Pod $pod_name terminated"
            return 0
        fi
        sleep 1
    done

    log_error "Timeout waiting for pod to terminate"
    return 1
}

get_pod_restart_count() {
    local pod_name=$1
    local namespace=${2:-${NAMESPACE}}

    kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0"
}

get_pod_phase() {
    local pod_name=$1
    local namespace=${2:-${NAMESPACE}}

    kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown"
}

get_pod_ready_condition() {
    local pod_name=$1
    local namespace=${2:-${NAMESPACE}}

    kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown"
}

scale_statefulset() {
    local statefulset=$1
    local replicas=$2
    local namespace=${3:-${NAMESPACE}}

    log_info "Scaling $statefulset to $replicas replicas..."
    kubectl scale statefulset "$statefulset" -n "$namespace" --replicas="$replicas"
}

get_statefulset_ready_replicas() {
    local statefulset=$1
    local namespace=${2:-${NAMESPACE}}

    kubectl get statefulset "$statefulset" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0"
}

# Pod exec helpers
pod_exec() {
    local pod_name=$1
    local namespace=$2
    shift 2
    local command="$*"

    kubectl exec "$pod_name" -n "$namespace" -- sh -c "$command"
}

pod_exec_with_output() {
    local pod_name=$1
    local namespace=$2
    shift 2
    local command="$*"

    kubectl exec "$pod_name" -n "$namespace" -- sh -c "$command" 2>&1
}

# File operations on pods
pod_write_file() {
    local pod_name=$1
    local namespace=$2
    local file_path=$3
    local content=$4

    kubectl exec "$pod_name" -n "$namespace" -- sh -c "echo '$content' > '$file_path'"
}

pod_read_file() {
    local pod_name=$1
    local namespace=$2
    local file_path=$3

    kubectl exec "$pod_name" -n "$namespace" -- cat "$file_path" 2>/dev/null || echo ""
}

pod_file_exists() {
    local pod_name=$1
    local namespace=$2
    local file_path=$3

    kubectl exec "$pod_name" -n "$namespace" -- test -f "$file_path" && echo "true" || echo "false"
}

pod_delete_file() {
    local pod_name=$1
    local namespace=$2
    local file_path=$3

    kubectl exec "$pod_name" -n "$namespace" -- rm -f "$file_path"
}

# Logs and debugging
show_pod_logs() {
    local pod_name=$1
    local namespace=${2:-${NAMESPACE}}
    local lines=${3:-50}

    echo "=== Logs from $pod_name ==="
    kubectl logs "$pod_name" -n "$namespace" --tail="$lines"
    echo "==========================="
}

show_pod_events() {
    local pod_name=$1
    local namespace=${2:-${NAMESPACE}}

    echo "=== Events for $pod_name ==="
    kubectl get events -n "$namespace" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp'
    echo "============================"
}

describe_pod() {
    local pod_name=$1
    local namespace=${2:-${NAMESPACE}}

    kubectl describe pod "$pod_name" -n "$namespace"
}

# Cleanup helpers
cleanup_test_resources() {
    local namespace=${1:-${NAMESPACE}}

    log_info "Cleaning up test resources in namespace $namespace..."

    # Delete all test jobs
    kubectl delete jobs -n "$namespace" -l test-suite=s3sweep-k8s --ignore-not-found=true

    # Scale down StatefulSet
    kubectl scale statefulset rclone-worker -n "$namespace" --replicas=0 2>/dev/null || true

    log_success "Cleanup complete"
}

# Wait for condition helper
wait_for_condition() {
    local condition_function=$1
    local max_wait=${2:-60}
    local interval=${3:-2}

    for i in $(seq 1 $((max_wait / interval))); do
        if eval "$condition_function"; then
            return 0
        fi
        sleep "$interval"
    done

    return 1
}

# Retry helper
retry() {
    local max_attempts=${1:-3}
    local delay=${2:-2}
    shift 2
    local command="$*"

    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if eval "$command"; then
            return 0
        fi

        log_warn "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
        sleep "$delay"
        attempt=$((attempt + 1))
    done

    log_error "All $max_attempts attempts failed"
    return 1
}

# Export functions for use in test scripts
export -f log_info log_success log_error log_warn
export -f test_suite_start test_start test_pass test_fail test_suite_end
export -f assert_equals assert_not_equals assert_true assert_false
export -f assert_not_empty assert_empty assert_contains assert_file_exists
export -f wait_for_ready_pods wait_for_pod_termination
export -f get_pod_restart_count get_pod_phase get_pod_ready_condition
export -f scale_statefulset get_statefulset_ready_replicas
export -f pod_exec pod_exec_with_output
export -f pod_write_file pod_read_file pod_file_exists pod_delete_file
export -f show_pod_logs show_pod_events describe_pod
export -f cleanup_test_resources wait_for_condition retry
