# S3Sweep Kubernetes Tests

Comprehensive Kubernetes test suite for s3sweep worker deployment.

## Test Coverage

### K8S-001 to K8S-005: Scaling (test_scaling.sh)
- **K8S-001**: Scale up from 1 to 3 replicas, verify new workers join
- **K8S-002**: Scale down from 3 to 1, verify graceful shutdown
- **K8S-003**: Scale to zero, verify all workers stop gracefully
- **K8S-004**: Rapid scaling changes (stress test)
- **K8S-005**: Worker identity matches pod ordinal

### K8S-010 to K8S-013: Health Probes (test_probes.sh)
- **K8S-010**: Readiness probe passes after /tmp/healthy creation
- **K8S-011**: Liveness probe passes continuously during work
- **K8S-012**: /tmp/healthy removed on graceful shutdown
- **K8S-013**: Stuck worker detection via liveness probe

### K8S-006 to K8S-009: Orphan Recovery (test_orphan_recovery.sh)
- **K8S-006**: Pod crash mid-job leaves orphan in processing/
- **K8S-007**: Orphan recovery moves jobs to pending/
- **K8S-008**: Node failure with pod reschedule
- **K8S-009**: Container restart resumes job polling

### K8S-014 to K8S-016: Termination (test_termination.sh)
- **K8S-014**: Normal SIGTERM allows current job completion
- **K8S-015**: Termination timeout forces SIGKILL
- **K8S-016**: Rolling update with zero downtime

### K8S-017 to K8S-020: Volumes (test_volumes.sh)
- **K8S-017**: Shared PVC accessible by all workers
- **K8S-018**: Data directory isolation per worker
- **K8S-019**: rclone.conf mounted and accessible
- **K8S-020**: Secret rotation handling

## Prerequisites

Required tools:
- `kind` (Kubernetes in Docker)
- `kubectl` (Kubernetes CLI)
- `docker` (Container runtime)
- `jq` (JSON processor)

Install on macOS:
```bash
brew install kind kubectl docker jq
```

Install on Linux:
```bash
# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# jq
sudo apt-get install jq
```

## Quick Start

### 1. Setup Test Environment

```bash
cd tests/k8s
./setup.sh
```

This will:
- Create a Kind cluster with 1 control plane + 3 worker nodes
- Install local storage provisioner
- Deploy MinIO for S3 testing
- Build and load s3sweep:test image
- Deploy s3sweep StatefulSet

### 2. Run All Tests

```bash
# Run individual test suites
./test_scaling.sh
./test_probes.sh
./test_orphan_recovery.sh
./test_termination.sh
./test_volumes.sh

# Or run all tests
for test in test_*.sh; do
    ./$test || echo "Failed: $test"
done
```

### 3. Run Specific Test

```bash
# Source test file and run specific test
source test_helpers.sh
source test_scaling.sh

# Run single test
test_scale_up
```

## Test Environment

### Kind Cluster Configuration

- **Cluster name**: s3sweep-test
- **Nodes**: 1 control plane + 3 workers
- **Storage**: local-path provisioner (default)
- **Registry**: Local Docker registry at localhost:5001

### MinIO Configuration

- **API Endpoint**: http://localhost:9000
- **Console**: http://localhost:9001
- **Username**: minioadmin
- **Password**: minioadmin
- **Test Buckets**: test-bucket-a, test-bucket-b, test-bucket-c
- **Test Files**: 100 files per bucket

### S3Sweep Deployment

- **Namespace**: s3sweep-test
- **StatefulSet**: rclone-worker
- **Initial Replicas**: 1
- **Image**: s3sweep:test
- **Storage**: emptyDir (for testing)

## Manual Testing

### Access Pods

```bash
# List pods
kubectl get pods -n s3sweep-test

# Exec into pod
kubectl exec -it rclone-worker-0 -n s3sweep-test -- sh

# View logs
kubectl logs -f rclone-worker-0 -n s3sweep-test
```

### Scale Workers

```bash
# Scale up
kubectl scale statefulset rclone-worker -n s3sweep-test --replicas=3

# Scale down
kubectl scale statefulset rclone-worker -n s3sweep-test --replicas=1

# Watch scaling
kubectl get pods -n s3sweep-test -w
```

### Test rclone Connectivity

```bash
# List MinIO buckets
kubectl exec rclone-worker-0 -n s3sweep-test -- rclone lsd s3_a:

# Download test file
kubectl exec rclone-worker-0 -n s3sweep-test -- \
    rclone copyto s3_a:test-bucket-a/path/to/file-1.txt /tmp/test.txt

# Verify download
kubectl exec rclone-worker-0 -n s3sweep-test -- cat /tmp/test.txt
```

### Inspect Configuration

```bash
# View rclone config
kubectl exec rclone-worker-0 -n s3sweep-test -- cat /etc/rclone/rclone.conf

# Check environment variables
kubectl exec rclone-worker-0 -n s3sweep-test -- env | grep WORKER

# View StatefulSet spec
kubectl get statefulset rclone-worker -n s3sweep-test -o yaml
```

## Test Helpers

The `test_helpers.sh` file provides reusable functions:

### Assertion Functions
- `assert_equals <expected> <actual> [message]`
- `assert_not_equals <expected> <actual> [message]`
- `assert_true <condition> [message]`
- `assert_false <condition> [message]`
- `assert_not_empty <value> [message]`
- `assert_contains <haystack> <needle> [message]`

### Kubernetes Helpers
- `wait_for_ready_pods <count> [namespace] [timeout]`
- `wait_for_pod_termination <pod> [namespace] [timeout]`
- `scale_statefulset <name> <replicas> [namespace]`
- `get_pod_restart_count <pod> [namespace]`
- `get_pod_phase <pod> [namespace]`

### Pod Operations
- `pod_exec <pod> <namespace> <command>`
- `pod_write_file <pod> <namespace> <path> <content>`
- `pod_read_file <pod> <namespace> <path>`
- `pod_file_exists <pod> <namespace> <path>`

### Debugging
- `show_pod_logs <pod> [namespace] [lines]`
- `show_pod_events <pod> [namespace]`
- `describe_pod <pod> [namespace]`

## Troubleshooting

### Tests Failing

```bash
# Check pod status
kubectl get pods -n s3sweep-test

# View pod logs
kubectl logs rclone-worker-0 -n s3sweep-test

# Describe pod for events
kubectl describe pod rclone-worker-0 -n s3sweep-test

# Check MinIO connectivity
kubectl exec rclone-worker-0 -n s3sweep-test -- rclone listremotes
```

### Cluster Issues

```bash
# View cluster info
kubectl cluster-info --context kind-s3sweep-test

# Check node status
kubectl get nodes

# View all resources
kubectl get all -n s3sweep-test
```

### Reset Environment

```bash
# Delete and recreate cluster
kind delete cluster --name s3sweep-test
./setup.sh

# Or just reset namespace
kubectl delete namespace s3sweep-test
kubectl create namespace s3sweep-test
kubectl apply -k .
```

## Cleanup

```bash
# Delete Kind cluster
kind delete cluster --name s3sweep-test

# Delete local registry (optional)
docker stop kind-registry
docker rm kind-registry
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Kubernetes Tests

on: [push, pull_request]

jobs:
  k8s-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install tools
        run: |
          curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
          chmod +x ./kind
          sudo mv ./kind /usr/local/bin/kind
          sudo apt-get install -y jq

      - name: Setup test environment
        run: cd tests/k8s && ./setup.sh

      - name: Run tests
        run: |
          cd tests/k8s
          ./test_scaling.sh
          ./test_probes.sh
          ./test_orphan_recovery.sh
          ./test_termination.sh
          ./test_volumes.sh

      - name: Cleanup
        if: always()
        run: kind delete cluster --name s3sweep-test
```

## Contributing

When adding new tests:

1. Add test function to appropriate test file
2. Follow naming convention: `test_<name>()`
3. Use test helpers for assertions
4. Include descriptive log messages
5. Clean up resources after test
6. Update test coverage in this README

## Test Development Guidelines

- **Isolation**: Each test should be independent
- **Cleanup**: Always clean up resources
- **Timing**: Use appropriate timeouts for k8s operations
- **Assertions**: Use helper functions, not raw bash conditionals
- **Logging**: Include informative messages for debugging
- **Idempotency**: Tests should be repeatable

## License

Same as s3sweep project.
