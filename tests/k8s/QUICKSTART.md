# S3Sweep K8s Tests - Quick Start

## 5-Minute Setup

```bash
cd tests/k8s

# 1. Setup (one time, ~3-5 minutes)
./setup.sh

# 2. Run all tests (~10 minutes)
./run_all_tests.sh

# 3. Run specific test suite
./test_scaling.sh
./test_probes.sh
./test_orphan_recovery.sh
./test_termination.sh
./test_volumes.sh
```

## Skip Setup (Use Existing Cluster)

```bash
# Run tests on existing cluster
./run_all_tests.sh --skip-setup

# Or run individual tests
./test_scaling.sh
```

## Common Commands

### Cluster Management

```bash
# Create cluster
./setup.sh

# Delete cluster
kind delete cluster --name s3sweep-test

# Check cluster status
kubectl cluster-info
kubectl get nodes
```

### View Resources

```bash
# List all pods
kubectl get pods -n s3sweep-test

# Watch pod status
kubectl get pods -n s3sweep-test -w

# View logs
kubectl logs -f rclone-worker-0 -n s3sweep-test

# Exec into pod
kubectl exec -it rclone-worker-0 -n s3sweep-test -- sh
```

### Scale Workers

```bash
# Scale up
kubectl scale statefulset rclone-worker -n s3sweep-test --replicas=3

# Scale down
kubectl scale statefulset rclone-worker -n s3sweep-test --replicas=1

# Scale to zero
kubectl scale statefulset rclone-worker -n s3sweep-test --replicas=0
```

### MinIO Access

```bash
# Access MinIO console
open http://localhost:9001

# Or via CLI in pod
kubectl exec rclone-worker-0 -n s3sweep-test -- rclone lsd s3_a:
```

## Troubleshooting

### Tests Failing?

```bash
# Check pod status
kubectl get pods -n s3sweep-test

# View recent logs
kubectl logs rclone-worker-0 -n s3sweep-test --tail=50

# Describe pod (shows events)
kubectl describe pod rclone-worker-0 -n s3sweep-test

# Check MinIO is running
kubectl get pods -n minio
```

### Reset Environment

```bash
# Quick reset: delete and recreate namespace
kubectl delete namespace s3sweep-test
kubectl create namespace s3sweep-test
kubectl apply -k .

# Full reset: recreate cluster
kind delete cluster --name s3sweep-test
./setup.sh
```

### Debug Specific Test

```bash
# Run with verbose output
VERBOSE=1 ./test_scaling.sh

# Stop on first failure
STOP_ON_FAILURE=1 ./run_all_tests.sh

# Run single test function
source test_helpers.sh
source test_scaling.sh
test_scale_up  # Run specific test
```

## Test Environment Details

- **Cluster**: s3sweep-test (1 control plane + 3 workers)
- **Namespace**: s3sweep-test
- **MinIO**: http://localhost:9000 (admin/admin)
- **Image**: s3sweep:test
- **Storage**: local-path (default)

## Quick Reference

### Test Files

| File | Tests |
|------|-------|
| `test_scaling.sh` | K8S-001 to K8S-005 |
| `test_probes.sh` | K8S-010 to K8S-013 |
| `test_orphan_recovery.sh` | K8S-006 to K8S-009 |
| `test_termination.sh` | K8S-014 to K8S-016 |
| `test_volumes.sh` | K8S-017 to K8S-020 |

### Helper Functions

```bash
# In any test script:
source test_helpers.sh

# Assertions
assert_equals "expected" "$actual" "message"
assert_true "[ $x -eq 1 ]" "message"

# K8s operations
wait_for_ready_pods 3
scale_statefulset rclone-worker 5
pod_exec rclone-worker-0 s3sweep-test "ls -la"

# Debugging
show_pod_logs rclone-worker-0
show_pod_events rclone-worker-0
```

## CI/CD

Tests run automatically on GitHub Actions:

```yaml
# .github/workflows/k8s-tests.yml
on: [push, pull_request]
```

View results: `Actions` tab in GitHub

## Need Help?

- Full documentation: [README.md](README.md)
- Test helpers: [test_helpers.sh](test_helpers.sh)
- Setup script: [setup.sh](setup.sh)

## Tips

1. **First time**: Run `./setup.sh` once, then reuse cluster for multiple test runs
2. **Fast iteration**: Use `--skip-setup` to save time
3. **Debug**: Use `kubectl logs`, `kubectl describe`, and `kubectl exec`
4. **Clean state**: Delete namespace to reset: `kubectl delete ns s3sweep-test`
5. **Parallel**: Tests are designed to run sequentially (cleanup between tests)

## Common Test Patterns

```bash
# Test specific behavior
./test_scaling.sh              # Just scaling tests

# Debug failed test
VERBOSE=1 ./test_probes.sh     # See all output

# Stop on first failure
STOP_ON_FAILURE=1 ./run_all_tests.sh

# Run on existing cluster (fast)
./run_all_tests.sh --skip-setup

# Run specific suite
./run_all_tests.sh --suite test_scaling.sh

# List available suites
./run_all_tests.sh --list
```
