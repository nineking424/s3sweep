#!/usr/bin/env bash
# Setup script for s3sweep on REAL Kubernetes cluster
# Uses containerd import to load images on cluster nodes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
NAMESPACE="s3sweep-test"
MINIO_NAMESPACE="minio-test"
IMAGE_NAME="s3sweep"
IMAGE_TAG="test"
IMAGE_TARBALL="/tmp/${IMAGE_NAME}-${IMAGE_TAG}.tar"

# Cluster nodes (update if your cluster has different node names)
CLUSTER_NODES=("nknode01" "nknode02" "nknode03" "nknode04")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

#############################################
# Pre-flight Checks
#############################################

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Required tools (NOT kind!)
    local tools=("kubectl" "docker" "ssh")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "Required tool not found: $tool"
            exit 1
        fi
    done
    log_info "All required tools available"

    # Verify cluster connectivity
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    log_info "Kubernetes cluster accessible"

    # Verify correct context
    local context
    context=$(kubectl config current-context)
    log_info "Current context: $context"

    # Verify SSH connectivity to all nodes
    log_info "Verifying SSH connectivity to cluster nodes..."
    for node in "${CLUSTER_NODES[@]}"; do
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$node" "echo ok" &>/dev/null; then
            log_error "Cannot SSH to node: $node"
            log_error "Ensure SSH key authentication is configured for: $node"
            exit 1
        fi
        log_info "  - $node: OK"
    done

    # Verify default storageClass exists
    log_info "Checking for default storageClass..."
    if ! kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
        log_warn "No default storageClass found!"
        log_warn "Available storageClasses:"
        kubectl get storageclass 2>/dev/null || echo "  (none)"
        log_error "MinIO PVC requires a default storageClass. Either:"
        log_error "  1. Mark an existing storageClass as default"
        log_error "  2. Edit minio-test.yaml to specify storageClassName"
        exit 1
    fi
    log_info "Default storageClass found"

    # Safety check: verify test namespaces don't have non-test resources
    for ns in "$NAMESPACE" "$MINIO_NAMESPACE"; do
        if kubectl get namespace "$ns" &>/dev/null; then
            # Namespace exists - check for non-test resources
            local non_test_pods
            non_test_pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -v "test-suite=s3sweep-k8s" | wc -l || echo "0")
            if [[ "$non_test_pods" -gt 0 ]]; then
                log_error "Namespace '$ns' contains pods NOT labeled with test-suite=s3sweep-k8s"
                log_error "This may indicate production workloads. Aborting for safety."
                log_error "To override, manually delete the namespace first: kubectl delete ns $ns"
                exit 1
            fi
            log_warn "Namespace '$ns' exists (will be reused)"
        fi
    done
}

#############################################
# Image Build and Distribution
#############################################

build_and_distribute_image() {
    log_info "Building test image..."

    cd "$PROJECT_ROOT"

    # Build using production Dockerfile for amd64 (cluster architecture)
    # Using buildx for cross-platform build from arm64 Mac to amd64 cluster
    docker buildx build --platform linux/amd64 -t "${IMAGE_NAME}:${IMAGE_TAG}" -f Dockerfile --load .

    # Save to tarball
    log_info "Saving image to tarball: ${IMAGE_TARBALL}"
    docker save "${IMAGE_NAME}:${IMAGE_TAG}" -o "${IMAGE_TARBALL}"

    # Distribute to all nodes via SSH + containerd import
    log_info "Distributing image to cluster nodes..."
    for node in "${CLUSTER_NODES[@]}"; do
        log_info "  Importing to $node..."

        # Copy tarball to node
        scp -q "${IMAGE_TARBALL}" "${node}:/tmp/"

        # Import into containerd's k8s.io namespace
        ssh "$node" "sudo ctr -n k8s.io images import /tmp/$(basename ${IMAGE_TARBALL}) && rm /tmp/$(basename ${IMAGE_TARBALL})"

        log_info "    $node: imported successfully"
    done

    # Cleanup local tarball
    rm -f "${IMAGE_TARBALL}"

    log_info "Image distributed to all nodes"
}

#############################################
# MinIO Deployment
#############################################

deploy_minio() {
    log_info "Deploying MinIO to ${MINIO_NAMESPACE}..."

    cd "$SCRIPT_DIR"

    # Apply MinIO resources (namespace included in YAML)
    kubectl apply -f minio-test.yaml

    # Wait for MinIO pod to be ready
    log_info "Waiting for MinIO pod to be ready..."
    kubectl wait --for=condition=ready pod -l app=minio -n "${MINIO_NAMESPACE}" --timeout=120s

    # Wait for minio-setup job to complete
    log_info "Waiting for minio-setup job to complete..."
    kubectl wait --for=condition=complete job/minio-setup -n "${MINIO_NAMESPACE}" --timeout=180s

    log_info "MinIO deployed and setup complete"
}

#############################################
# S3Sweep Deployment
#############################################

deploy_s3sweep() {
    log_info "Deploying s3sweep to ${NAMESPACE}..."

    cd "$SCRIPT_DIR"

    # Create namespace if not exists
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    # Label namespace for test identification
    kubectl label namespace "${NAMESPACE}" test-suite=s3sweep-k8s environment=test --overwrite

    # Apply kustomization
    kubectl apply -k .

    # Wait for rollout
    log_info "Waiting for StatefulSet rollout..."
    kubectl rollout status statefulset/rclone-worker -n "${NAMESPACE}" --timeout=120s

    log_info "s3sweep deployed successfully"
}

#############################################
# Verification
#############################################

verify_deployment() {
    log_info "Verifying deployment..."

    echo ""
    echo "=== MinIO Status ==="
    kubectl get pods -n "${MINIO_NAMESPACE}" -l app=minio
    kubectl get jobs -n "${MINIO_NAMESPACE}"

    echo ""
    echo "=== S3Sweep Status ==="
    kubectl get pods -n "${NAMESPACE}"
    kubectl get statefulset -n "${NAMESPACE}"

    echo ""
    log_info "Deployment verification complete"
}

#############################################
# Main
#############################################

main() {
    echo "=========================================="
    echo "S3Sweep Real Cluster Setup"
    echo "=========================================="
    echo ""

    check_prerequisites
    build_and_distribute_image
    deploy_minio
    deploy_s3sweep
    verify_deployment

    echo ""
    log_info "Setup complete! You can now run tests:"
    log_info "  cd ${SCRIPT_DIR} && ./run_all_tests.sh --skip-setup"
}

main "$@"
