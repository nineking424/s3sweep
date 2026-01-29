# S3Sweep Kubernetes Test Coverage

Complete test coverage matrix for s3sweep StatefulSet deployment.

## Test Suite Overview

| Suite | Tests | Description | Runtime |
|-------|-------|-------------|---------|
| test_scaling.sh | K8S-001 to K8S-005 | Worker scaling behavior | ~2 min |
| test_probes.sh | K8S-010 to K8S-013 | Health check mechanisms | ~3 min |
| test_orphan_recovery.sh | K8S-006 to K8S-009 | Failure recovery patterns | ~3 min |
| test_termination.sh | K8S-014 to K8S-016 | Graceful shutdown | ~2 min |
| test_volumes.sh | K8S-017 to K8S-020 | Storage and config | ~2 min |

**Total:** 20 test cases, ~12 minutes runtime

## Detailed Test Coverage

### Scaling Operations (K8S-001 to K8S-005)

| Test ID | Test Name | What It Validates | Pass Criteria |
|---------|-----------|-------------------|---------------|
| K8S-001 | Scale Up | Workers join cluster when scaling 1→3 | All 3 pods Running and Ready |
| K8S-002 | Scale Down | Workers exit gracefully when scaling 3→1 | Only worker-0 remains, others terminated |
| K8S-003 | Scale to Zero | All workers stop cleanly | Zero pods remaining, no errors |
| K8S-004 | Rapid Scaling | System handles quick scale changes (1→5→2→4→1) | Stable final state with 1 worker |
| K8S-005 | Worker Identity | WORKER_ID matches pod ordinal | worker-0 has ID=0, worker-1 has ID=1, etc. |

**Key Validations:**
- StatefulSet identity preservation
- Environment variable injection (WORKER_ID, TOTAL_WORKERS)
- Pod hostname matches StatefulSet name pattern
- No crashes during scaling operations

### Health Probes (K8S-010 to K8S-013)

| Test ID | Test Name | What It Validates | Pass Criteria |
|---------|-----------|-------------------|---------------|
| K8S-010 | Readiness on Startup | Pod not Ready until /tmp/healthy exists | Ready status changes from False to True |
| K8S-011 | Liveness During Work | Health checks pass continuously | No restarts over 30s period |
| K8S-012 | Health Removed on Shutdown | Graceful shutdown removes health file | /tmp/healthy deleted before termination |
| K8S-013 | Stuck Worker Detection | Liveness failure triggers restart | Pod restarted when /tmp/healthy removed |

**Key Validations:**
- Readiness probe prevents premature traffic routing
- Liveness probe detects hung workers
- Health file management in signal handlers
- Kubelet restart behavior on probe failures

### Orphan Recovery (K8S-006 to K8S-009)

| Test ID | Test Name | What It Validates | Pass Criteria |
|---------|-----------|-------------------|---------------|
| K8S-006 | Pod Crash Mid-Job | Jobs in processing/ survive pod crash | Orphan job persists in processing/ |
| K8S-007 | Orphan Recovery | Orphans moved to pending/ on restart | All processing/ jobs moved to pending/ |
| K8S-008 | Node Failure | Pods reschedule to healthy nodes | Pod restarts on different node |
| K8S-009 | Container Restart | Job state preserved across restarts | Pending jobs still exist after restart |

**Key Validations:**
- Shared storage preserves job state
- Orphan detection logic on startup
- Job reprocessing after failures
- StatefulSet reschedule behavior

### Termination Handling (K8S-014 to K8S-016)

| Test ID | Test Name | What It Validates | Pass Criteria |
|---------|-----------|-------------------|---------------|
| K8S-014 | Normal Termination | SIGTERM allows current job completion | Health file removed, graceful exit |
| K8S-015 | Termination Timeout | SIGKILL after grace period expires | Pod force-killed after terminationGracePeriodSeconds |
| K8S-016 | Rolling Update | Zero-downtime updates | Pods updated in reverse ordinal order |

**Key Validations:**
- SIGTERM signal handling
- terminationGracePeriodSeconds enforcement
- Rolling update strategy (RollingUpdate type)
- StatefulSet ordered termination (N-1 to 0)

### Volume and Configuration (K8S-017 to K8S-020)

| Test ID | Test Name | What It Validates | Pass Criteria |
|---------|-----------|-------------------|---------------|
| K8S-017 | Shared PVC Access | All workers access shared volume | Files written by one worker visible to all |
| K8S-018 | Data Dir Isolation | Workers respect directory boundaries | Each worker uses isolated subdirectory |
| K8S-019 | rclone Config Mount | ConfigMap/Secret projection works | rclone.conf readable, remotes listed |
| K8S-020 | Secret Rotation | Config updates propagate | New credentials picked up after pod restart |

**Key Validations:**
- PersistentVolumeClaim sharing (ReadWriteMany)
- Projected volume mounting (ConfigMap + Secret)
- rclone configuration accessibility
- Secret update propagation timing

## Test Infrastructure

### Test Environment Components

```
┌─────────────────────────────────────────────────────────────┐
│                     Kind Cluster                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │ Control     │  │  Worker 1   │  │  Worker 2   │  ...   │
│  │ Plane       │  │  (zone-a)   │  │  (zone-b)   │        │
│  └─────────────┘  └─────────────┘  └─────────────┘        │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ s3sweep-test namespace                              │   │
│  │  ├─ StatefulSet: rclone-worker                      │   │
│  │  ├─ ConfigMap: rclone-config                        │   │
│  │  └─ Secret: rclone-secret                           │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ minio namespace                                      │   │
│  │  ├─ Deployment: minio                                │   │
│  │  ├─ Service: minio (9000, 9001)                      │   │
│  │  └─ PVC: minio-pvc                                   │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Test Helper Functions

**Assertions:**
- `assert_equals` - Exact value comparison
- `assert_not_equals` - Inequality check
- `assert_true` - Condition evaluation
- `assert_not_empty` - Non-empty validation
- `assert_contains` - Substring search

**Kubernetes Operations:**
- `wait_for_ready_pods` - Poll until N pods Ready
- `wait_for_pod_termination` - Wait for pod deletion
- `scale_statefulset` - Change replica count
- `get_pod_restart_count` - Get restart counter
- `get_pod_phase` - Get current pod phase

**Pod Operations:**
- `pod_exec` - Execute command in pod
- `pod_write_file` - Create file in pod
- `pod_read_file` - Read file from pod
- `pod_file_exists` - Check file existence

**Debugging:**
- `show_pod_logs` - Display recent logs
- `show_pod_events` - List pod events
- `describe_pod` - Full pod description

## Test Execution Patterns

### Standard Test Flow

```bash
test_name() {
    test_start "K8S-XXX: Test description"

    # 1. Setup initial state
    kubectl scale statefulset rclone-worker -n s3sweep-test --replicas=1
    wait_for_ready_pods 1

    # 2. Perform action
    local result=$(kubectl exec rclone-worker-0 -n s3sweep-test -- some_command)

    # 3. Assert expected outcome
    assert_equals "expected" "$result" "Validation message"

    # 4. Cleanup (if needed)
    kubectl exec rclone-worker-0 -n s3sweep-test -- cleanup_command

    test_pass
}
```

### Parallel Test Execution

Tests run **sequentially** within each suite to avoid resource conflicts:
- Each test resets to known state
- Cleanup between tests
- No shared mutable state

Suites can run in **any order** (independent):
```bash
# These are independent
./test_scaling.sh &
./test_probes.sh &
wait
```

## Coverage Gaps and Future Tests

### Not Yet Covered

1. **Network Partitions**: Simulate network splits between workers
2. **Storage Failures**: PVC unavailability scenarios
3. **Resource Limits**: CPU/memory throttling behavior
4. **Concurrent Job Processing**: Multiple workers processing same job pool
5. **Long-Running Jobs**: Jobs exceeding terminationGracePeriod
6. **ConfigMap Hot Reload**: Config changes without restart
7. **Multi-Zone Affinity**: Zone-aware scheduling validation
8. **Backup/Restore**: StatefulSet disaster recovery

### Known Limitations

1. **emptyDir Testing**: Tests use emptyDir instead of real NFS
   - Shared storage behavior approximated
   - Real NFS may have different semantics

2. **MinIO vs Real S3**: Tests use MinIO, not AWS S3
   - Different error modes
   - Different performance characteristics

3. **Single Cluster**: No multi-cluster federation tests

4. **No Chaos Testing**: No intentional failures injected
   - Would need chaos-mesh or similar

## Extending Test Coverage

### Adding New Test

1. Choose appropriate test file or create new suite
2. Follow naming convention: `test_<name>()`
3. Use test helpers for consistency
4. Include descriptive log messages
5. Clean up resources
6. Update this coverage document

Example:
```bash
# In test_scaling.sh
test_new_scaling_behavior() {
    test_start "K8S-XXX: New scaling behavior"

    # Setup
    scale_statefulset rclone-worker 2
    wait_for_ready_pods 2

    # Test
    local result=$(...)

    # Assert
    assert_equals "expected" "$result" "Description"

    test_pass
}
```

### Adding New Suite

1. Create `test_<suite>.sh`
2. Source `test_helpers.sh`
3. Implement test functions
4. Add `run_all_tests()` function
5. Make executable
6. Add to `TEST_SUITES` in `run_all_tests.sh`
7. Update documentation

## CI/CD Integration

### GitHub Actions

```yaml
# .github/workflows/k8s-tests.yml
- Run on: push, pull_request, workflow_dispatch
- Timeout: 30 minutes
- Runs all 5 test suites sequentially
- Collects logs on failure
```

### Local Development

```bash
# Quick iteration loop
while true; do
    ./test_scaling.sh
    sleep 5
done

# Or with file watching
fswatch -o worker-example.sh | xargs -n1 -I{} ./run_all_tests.sh --skip-setup
```

## Metrics and Benchmarks

| Metric | Target | Actual |
|--------|--------|--------|
| Test Suite Runtime | < 15 min | ~12 min |
| Setup Time | < 5 min | ~3 min |
| Individual Test | < 30 sec | 5-60 sec |
| Flaky Test Rate | < 1% | TBD |
| Code Coverage | > 80% | TBD |

## Test Maintenance

### Monthly Tasks
- [ ] Verify all tests pass on latest Kubernetes version
- [ ] Update kind to latest stable
- [ ] Review and update test timeouts
- [ ] Check for new rclone flags

### Quarterly Tasks
- [ ] Add tests for new features
- [ ] Review coverage gaps
- [ ] Update test infrastructure (MinIO, storage provisioner)
- [ ] Performance benchmark updates

### Before Releases
- [ ] Run full test suite 3x to check for flakes
- [ ] Test on multiple Kubernetes versions (1.28, 1.29, 1.30)
- [ ] Verify GitHub Actions pipeline passes
- [ ] Update test documentation

## References

- [Kind Documentation](https://kind.sigs.k8s.io/)
- [StatefulSet Documentation](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
- [Pod Lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
- [rclone Documentation](https://rclone.org/docs/)
