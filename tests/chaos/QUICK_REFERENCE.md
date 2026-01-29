# Chaos Test Quick Reference

## Run All Tests
```bash
./run_all_chaos_tests.sh
```

## Test Matrix

| Test ID | Category | Scenario | Expected Result |
|---------|----------|----------|-----------------|
| FAIL-001 | Network | S3 unreachable | Job → failed/ |
| FAIL-002 | Network | S3 timeout | Job → failed/ |
| FAIL-003 | Network | Intermittent S3 | Job → failed/processing |
| FAIL-004 | Network | Auth failure | Job → failed/ |
| FAIL-005 | Network | S3 throttled | Job → failed/slow |
| FAIL-006 | Invalid | Empty file | Job → failed/ |
| FAIL-007 | Invalid | No pipes | Job → failed/ |
| FAIL-008 | Invalid | Binary garbage | Job → failed/ |
| FAIL-009 | Invalid | Long path (>4096) | Job → failed/ |
| FAIL-010 | Invalid | Null bytes | Job → failed/ |
| FAIL-011 | Disk | Data disk full | Job → failed/ |
| FAIL-012 | Disk | Jobs disk full | Error logged |
| FAIL-013 | Disk | Read-only jobs | Error/stuck |
| FAIL-014 | Disk | Permission denied | Job → failed/ |
| FAIL-015 | Crash | SIGKILL during DL | Partial file + orphaned |
| FAIL-016 | Crash | OOM kill | Container killed |
| FAIL-017 | Crash | rclone crash | Job → failed/ |
| FAIL-018 | Crash | rclone hang | Job stuck/timeout |
| FAIL-019 | Edge | Job disappears | Error detected |
| FAIL-020 | Edge | mkdir fails | Job → failed/ |
| FAIL-021 | Edge | File exists | SUCCESS/FAILED (depends) |
| FAIL-022 | Edge | Zero-byte file | Job → completed/ |

## Test Groups

### Network Partition (`network_partition.sh`)
Uses Toxiproxy and Docker network manipulation.
```bash
./network_partition.sh
```

### Invalid Jobs (`invalid_jobs.sh`)
Tests malformed job file handling.
```bash
./invalid_jobs.sh
```

### Disk/Permission (`disk_full.sh`)
Uses tmpfs with size limits (no sudo).
```bash
./disk_full.sh
```

### Crash Scenarios (`crash.sh`)
Simulates worker/rclone crashes.
```bash
./crash.sh
```

### Edge Cases (`edge_cases.sh`)
Unusual but valid scenarios.
```bash
./edge_cases.sh
```

## Toxiproxy Quick Commands

```bash
# Start Toxiproxy
start_toxiproxy

# Create proxy
create_proxy s3_test localhost:20000 s3_a:9000

# Add 5-second latency
add_latency s3_test 5000 1000

# Add 50% packet loss
add_packet_loss s3_test 50

# Limit to 10 KB/s
add_bandwidth_limit s3_test 10

# Remove all toxics
remove_toxics s3_test

# Stop Toxiproxy
stop_toxiproxy
```

## Common Issues

### Toxiproxy won't start
```bash
docker stop toxiproxy-s3sweep
docker rm toxiproxy-s3sweep
```

### Cleanup after failed test
```bash
# Remove all test containers
docker ps -a | grep worker- | awk '{print $1}' | xargs docker rm -f

# Remove test networks
docker network rm s3sweep-test-net
```

### Check what's running
```bash
# List test containers
docker ps | grep -E 'worker-|toxiproxy'

# Check test networks
docker network ls | grep s3sweep
```

## Environment Variables

Tests use these variables (set automatically by helpers.sh):
- `TEST_DIR` - Temp directory for test artifacts
- `JOBS_DIR` - Job file directory
- `DATA_DIR` - Data output directory
- `TEST_NETWORK` - Docker network name
- `TEST_RCLONE_CONF` - Path to test rclone config

## Success Criteria

A test **PASSES** if:
1. Expected behavior occurs (job moves to correct directory)
2. Error is detected and logged appropriately
3. System remains stable (no crashes/hangs)

A test **FAILS** if:
1. Unexpected behavior occurs
2. System crashes or hangs without detection
3. Job ends up in wrong directory

## CI Integration

```yaml
# GitHub Actions
- name: Chaos Tests
  run: tests/chaos/run_all_chaos_tests.sh
  timeout-minutes: 15
```

Expected runtime: ~5-10 minutes for full suite.
