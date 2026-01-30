#!/usr/bin/env bash
# Cleanup script for s3sweep test resources on real cluster
# SAFETY: Only deletes namespaces containing test-labeled resources

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Test namespaces (using minio-test, NOT minio)
NAMESPACES=("s3sweep-test" "minio-test")

echo "==================================="
echo "S3Sweep Test Cleanup"
echo "==================================="
echo ""
echo "This will delete the following namespaces:"
for ns in "${NAMESPACES[@]}"; do
    echo "  - $ns"
done
echo ""

#############################################
# Safety Pre-flight Check
#############################################

log_info "Running safety checks..."

for ns in "${NAMESPACES[@]}"; do
    if kubectl get namespace "$ns" &>/dev/null; then
        # Check for resources NOT labeled as test resources
        non_test_count=$(kubectl get all -n "$ns" -o json 2>/dev/null | \
            jq '[.items[] | select(.metadata.labels."test-suite" != "s3sweep-k8s")] | length' || echo "0")

        if [[ "$non_test_count" -gt 0 ]]; then
            log_error "SAFETY ABORT: Namespace '$ns' contains $non_test_count resources WITHOUT test-suite label!"
            log_error "These may be production resources. Manual inspection required."
            log_error ""
            log_error "To see unlabeled resources:"
            log_error "  kubectl get all -n $ns --show-labels | grep -v test-suite"
            log_error ""
            log_error "To force cleanup anyway, manually delete:"
            log_error "  kubectl delete ns $ns"
            exit 1
        fi
        log_info "  $ns: safe (all resources are test-labeled)"
    else
        log_info "  $ns: does not exist (nothing to clean)"
    fi
done

echo ""

# Confirm before proceeding
read -p "Proceed with cleanup? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

#############################################
# Cleanup Execution
#############################################

for ns in "${NAMESPACES[@]}"; do
    if kubectl get namespace "$ns" &>/dev/null; then
        log_info "Deleting namespace: $ns"

        # Delete all resources in namespace first
        kubectl delete all --all -n "$ns" --timeout=60s 2>/dev/null || true

        # Delete PVCs
        kubectl delete pvc --all -n "$ns" --timeout=60s 2>/dev/null || true

        # Delete namespace
        kubectl delete namespace "$ns" --timeout=120s || log_warn "Namespace $ns deletion timed out"
    else
        log_info "Namespace $ns does not exist, skipping"
    fi
done

#############################################
# Verification
#############################################

echo ""
log_info "Verifying cleanup..."

all_clean=true
for ns in "${NAMESPACES[@]}"; do
    if kubectl get namespace "$ns" &>/dev/null; then
        log_warn "Namespace $ns still exists!"
        all_clean=false
    else
        log_info "Namespace $ns successfully deleted"
    fi
done

# Check for any orphaned resources with test labels
orphans=$(kubectl get all --all-namespaces -l test-suite=s3sweep-k8s --no-headers 2>/dev/null | wc -l || echo "0")
if [[ "$orphans" -gt 0 ]]; then
    log_warn "Found $orphans orphaned resources with test labels:"
    kubectl get all --all-namespaces -l test-suite=s3sweep-k8s
    all_clean=false
fi

echo ""
if [[ "$all_clean" == "true" ]]; then
    log_info "Cleanup complete! All test resources removed."
else
    log_warn "Cleanup finished with warnings. Some resources may need manual cleanup."
fi
