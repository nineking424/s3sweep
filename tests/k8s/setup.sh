#!/usr/bin/env bash
# Setup script for s3sweep Kubernetes test environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-s3sweep-test}"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    command -v kind >/dev/null 2>&1 || missing+=("kind")
    command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
    command -v docker >/dev/null 2>&1 || missing+=("docker")

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Please install them before running this script"
        exit 1
    fi

    log_info "All prerequisites satisfied"
}

create_local_registry() {
    log_info "Setting up local Docker registry..."

    # Check if registry already exists
    if docker ps --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
        log_info "Registry ${REGISTRY_NAME} already running"
        return
    fi

    # Create registry container
    docker run -d \
        --restart=always \
        -p "127.0.0.1:${REGISTRY_PORT}:5000" \
        --name "${REGISTRY_NAME}" \
        registry:2 || log_warn "Registry creation failed or already exists"

    log_info "Registry available at localhost:${REGISTRY_PORT}"
}

create_kind_cluster() {
    log_info "Creating kind cluster: ${CLUSTER_NAME}..."

    # Check if cluster already exists
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        log_warn "Cluster ${CLUSTER_NAME} already exists"
        read -p "Delete and recreate? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Deleting existing cluster..."
            kind delete cluster --name "${CLUSTER_NAME}"
        else
            log_info "Using existing cluster"
            return
        fi
    fi

    # Create cluster with config
    kind create cluster \
        --name "${CLUSTER_NAME}" \
        --config "${SCRIPT_DIR}/kind-config.yaml"

    # Connect registry to cluster network
    if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REGISTRY_NAME}")" = 'null' ]; then
        docker network connect "kind" "${REGISTRY_NAME}" || true
    fi

    # Document local registry
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

    log_info "Cluster ${CLUSTER_NAME} created successfully"
}

install_storage_provisioner() {
    log_info "Installing local-path storage provisioner..."

    # Check if already installed
    if kubectl get storageclass local-path >/dev/null 2>&1; then
        log_info "local-path storage already installed"
        return
    fi

    # Install Rancher local-path provisioner
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml

    # Wait for provisioner to be ready
    kubectl wait --for=condition=ready pod \
        -l app=local-path-provisioner \
        -n local-path-storage \
        --timeout=60s

    # Set as default storage class
    kubectl patch storageclass local-path \
        -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

    log_info "Storage provisioner installed"
}

build_and_load_image() {
    log_info "Building s3sweep test image..."

    cd "$PROJECT_ROOT"

    # Build Docker image (assuming Dockerfile exists)
    if [ -f "Dockerfile" ]; then
        docker build -t s3sweep:test .
    else
        log_warn "No Dockerfile found, creating minimal test image..."
        cat > Dockerfile.test <<'EOF'
FROM alpine:latest
RUN apk add --no-cache bash curl jq rclone
WORKDIR /app
COPY worker-example.sh /app/worker.sh
RUN chmod +x /app/worker.sh
CMD ["/app/worker.sh"]
EOF
        docker build -f Dockerfile.test -t s3sweep:test .
        rm -f Dockerfile.test
    fi

    # Load image into kind cluster
    log_info "Loading image into kind cluster..."
    kind load docker-image s3sweep:test --name "${CLUSTER_NAME}"

    log_info "Image s3sweep:test loaded successfully"
}

deploy_minio() {
    log_info "Deploying MinIO..."

    # Create namespace
    kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -

    # Deploy MinIO
    kubectl apply -f "${SCRIPT_DIR}/minio.yaml"

    # Wait for MinIO to be ready
    log_info "Waiting for MinIO to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app=minio \
        -n minio \
        --timeout=120s

    # Wait for setup job to complete
    log_info "Waiting for MinIO setup to complete..."
    kubectl wait --for=condition=complete job/minio-setup \
        -n minio \
        --timeout=60s || log_warn "MinIO setup job may have failed"

    log_info "MinIO deployed and configured"
}

deploy_s3sweep() {
    log_info "Deploying s3sweep..."

    # Create namespace
    kubectl create namespace s3sweep-test --dry-run=client -o yaml | kubectl apply -f -

    # Apply kustomization
    kubectl apply -k "${SCRIPT_DIR}"

    # Wait for StatefulSet to be ready
    log_info "Waiting for s3sweep worker to be ready..."
    kubectl rollout status statefulset/rclone-worker \
        -n s3sweep-test \
        --timeout=120s || log_warn "Rollout status check timed out"

    log_info "s3sweep deployed successfully"
}

print_access_info() {
    log_info "Cluster setup complete!"
    echo
    echo "Cluster Information:"
    echo "  Cluster name: ${CLUSTER_NAME}"
    echo "  Kubectl context: kind-${CLUSTER_NAME}"
    echo
    echo "MinIO Access:"
    echo "  API: http://localhost:9000"
    echo "  Console: http://localhost:9001"
    echo "  Username: minioadmin"
    echo "  Password: minioadmin"
    echo
    echo "Test Commands:"
    echo "  kubectl get pods -n s3sweep-test"
    echo "  kubectl logs -f statefulset/rclone-worker -n s3sweep-test"
    echo "  kubectl exec -it rclone-worker-0 -n s3sweep-test -- sh"
    echo
    echo "Run tests:"
    echo "  cd ${SCRIPT_DIR}"
    echo "  ./test_scaling.sh"
    echo "  ./test_probes.sh"
    echo "  ./test_orphan_recovery.sh"
    echo
}

cleanup() {
    log_info "Cleaning up on error..."
}

# Main execution
trap cleanup ERR

main() {
    log_info "Starting s3sweep Kubernetes test environment setup"

    check_prerequisites
    create_local_registry
    create_kind_cluster
    install_storage_provisioner
    build_and_load_image
    deploy_minio
    deploy_s3sweep
    print_access_info

    log_info "Setup complete!"
}

# Allow sourcing for helper functions
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
