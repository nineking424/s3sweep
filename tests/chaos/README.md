# Chaos/Failure Testing Suite

This directory contains comprehensive failure scenario tests for s3sweep workers. All tests use **CI-friendly** chaos engineering techniques that don't require root privileges or iptables.

## Test Coverage

**Total: 22 failure scenarios (FAIL-001 to FAIL-022)**

### Network Partition Tests (FAIL-001 to FAIL-005)
Tests S3 connectivity failures using Docker network manipulation and Toxiproxy.

- **FAIL-001**: S3 completely unreachable (network disconnect)
- **FAIL-002**: S3 timeout (extreme latency via Toxiproxy)
- **FAIL-003**: S3 intermittent connectivity (50% packet loss)
- **FAIL-004**: S3 authentication failure (invalid credentials)
- **FAIL-005**: S3 throttled (bandwidth limit simulation)

### Invalid Job Tests (FAIL-006 to FAIL-010)
Tests worker behavior with malformed job files.

- **FAIL-006**: Empty job file
- **FAIL-007**: Malformed job (missing pipe separators)
- **FAIL-008**: Binary garbage in job file
- **FAIL-009**: Very long path (4096+ characters)
- **FAIL-010**: Null bytes in job file

### Disk/Permission Tests (FAIL-011 to FAIL-014)
Tests disk space and permission issues using tmpfs mounts.

- **FAIL-011**: Data disk full during download (tmpfs with size limit)
- **FAIL-012**: Jobs directory disk full
- **FAIL-013**: Jobs directory read-only
- **FAIL-014**: Permission denied on data directory

### Crash Scenario Tests (FAIL-015 to FAIL-018)
Tests worker/rclone crashes and hangs.

- **FAIL-015**: Worker killed (SIGKILL) during download
- **FAIL-016**: Worker OOM killed (memory limit)
- **FAIL-017**: rclone process crashes (mock exit code)
- **FAIL-018**: rclone hangs indefinitely (mock infinite sleep)

### Edge Case Tests (FAIL-019 to FAIL-022)
Tests unusual but valid scenarios.

- **FAIL-019**: Job disappears after being claimed (race condition)
- **FAIL-020**: Destination directory creation fails
- **FAIL-021**: Destination file already exists
- **FAIL-022**: Source file is zero bytes

## Chaos Techniques Used

### 1. Toxiproxy
Network failure simulation without iptables:
- Latency injection
- Timeout simulation
- Bandwidth throttling
- Packet loss

### 2. Docker Network Manipulation
- Network disconnect/connect
- Isolated test networks
- No host network modifications required

### 3. tmpfs Mounts
Disk full simulation without filling real disks:
- Size-limited tmpfs for data directories
- Predictable cleanup
- No risk of filling host disk

### 4. Docker Resource Limits
- Memory limits for OOM testing
- CPU limits (if needed)
- Read-only mounts for permission tests

### 5. Process Mocking
- Replace rclone with test doubles
- Simulate crashes, hangs, errors
- Control exit codes and timing

## Usage

### Run all chaos tests:
```bash
cd tests/chaos
./run_all_chaos_tests.sh
```

### Run individual test groups:
```bash
# Network partition tests only
./network_partition.sh

# Invalid job tests only
./invalid_jobs.sh

# Disk/permission tests
./disk_full.sh

# Crash scenarios
./crash.sh

# Edge cases
./edge_cases.sh
```

### Run individual tests:
```bash
# Source the test file and run specific test
source network_partition.sh
test_s3_unreachable
```

## Prerequisites

- Docker
- Docker network access
- Toxiproxy image: `ghcr.io/shopify/toxiproxy:latest`
- MinIO client (mc) configured
- Test S3 endpoints running (via docker-compose in tests/common/)

## CI Integration

All tests are designed for CI environments:

```yaml
# Example GitHub Actions workflow
- name: Run Chaos Tests
  run: |
    cd tests/chaos
    ./run_all_chaos_tests.sh
```

**CI-friendly features:**
- No root/sudo required
- No iptables manipulation
- Isolated Docker networks
- Automatic cleanup on exit
- Colored output with clear pass/fail

## Test Output

Tests report results in the format:
```
[FAIL-001] Testing S3 unreachable (network disconnect)...
  ✓ Job correctly moved to failed/

Network Partition Test Summary: PASS=5 FAIL=0
```

## Extending Tests

To add new failure scenarios:

1. Add test function to appropriate file (or create new file)
2. Follow naming convention: `test_<scenario_name>()`
3. Use test_name variable: `local test_name="FAIL-XXX"`
4. Update PASS/FAIL counters
5. Add to master test runner
6. Update this README

## Design Principles

1. **Isolation**: Each test runs in isolated environment
2. **Cleanup**: Automatic cleanup even on failure
3. **Determinism**: Predictable, repeatable results
4. **Speed**: Fast feedback (<5 min full suite)
5. **Safety**: No system-wide changes or risks

## Troubleshooting

### Toxiproxy won't start
```bash
# Check if port 8474 is in use
lsof -i :8474

# Manually stop Toxiproxy
docker stop toxiproxy-s3sweep
docker rm toxiproxy-s3sweep
```

### Docker network issues
```bash
# List test networks
docker network ls | grep s3sweep

# Clean up networks
docker network prune
```

### Tmpfs mount issues
- tmpfs mounts are Docker-managed, no host cleanup needed
- Check Docker daemon has sufficient memory
- Reduce tmpfs size in tests if needed

## Related Files

- `toxiproxy_setup.sh` - Toxiproxy wrapper functions
- `../common/helpers.sh` - Test helper functions
- `../../worker-example.sh` - Worker script under test
