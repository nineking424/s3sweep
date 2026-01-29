# Unit Test Coverage for worker.sh

## Test Summary
Total: **38 unit tests** implemented in `test_worker.bats`

## Coverage by Category

### 1.1 Job File Parsing (10 tests)
| Test ID | Description | Status |
|---------|-------------|--------|
| UNIT-001 | Valid 3-field job parses correctly | ✅ |
| UNIT-002 | Empty job file moves to failed/ | ✅ |
| UNIT-003 | Missing field (only 2 fields) moves to failed/ | ✅ |
| UNIT-004 | Extra fields (4 fields) REJECTED, moves to failed/ | ✅ |
| UNIT-005 | Pipe character in dst_path REJECTED, moves to failed/ | ✅ |
| UNIT-006 | Unicode characters in paths handled correctly | ✅ |
| UNIT-007 | Spaces in paths handled correctly | ✅ |
| UNIT-008 | Trailing newline ignored correctly | ✅ |
| UNIT-009 | Empty remote_name rejected | ✅ |
| UNIT-010 | Empty src_path rejected | ✅ |

### 1.2 Field Count Validation (3 tests)
| Test ID | Description | Status |
|---------|-------------|--------|
| UNIT-033 | Non-.txt file ignored by claim_job | ✅ |
| UNIT-034 | Exactly 2 pipes required for valid job | ✅ |
| UNIT-035 | dst_path validation - no pipes allowed in final field | ✅ |

### 1.3 Atomic Job Claiming (5 tests)
| Test ID | Description | Status |
|---------|-------------|--------|
| UNIT-011 | claim_job successfully claims and renames file | ✅ |
| UNIT-012 | claim_job returns nothing when no jobs available | ✅ |
| UNIT-013 | Job file disappears mid-processing handled gracefully | ✅ |
| UNIT-014 | Claimed file renamed with worker ID | ✅ |
| UNIT-015 | Oldest job file claimed first (FIFO ordering) | ✅ |

### 1.4 Worker ID Extraction (6 tests)
| Test ID | Description | Status |
|---------|-------------|--------|
| UNIT-016 | Worker ID extracted from hostname regex | ✅ |
| UNIT-017 | Worker ID handles double-digit pod numbers | ✅ |
| UNIT-018 | Worker ID from env overrides hostname when != 0 | ✅ |
| UNIT-019 | Worker ID defaults to 0 if no hostname pattern match | ✅ |
| UNIT-020 | Worker ID extracted from full pod name format | ✅ |
| UNIT-036 | Worker ID extraction with WORKER_ID=0 triggers hostname parsing | ✅ |

### 1.5 Structured Logging (4 tests)
| Test ID | Description | Status |
|---------|-------------|--------|
| UNIT-021 | log() produces valid JSON with all required fields | ✅ |
| UNIT-022 | log_job() includes elapsed_ms and job_file | ✅ |
| UNIT-023 | Timestamp format is ISO8601 UTC | ✅ |
| UNIT-024 | JSON escaping in log messages with special characters | ✅ |

### 1.6 Graceful Shutdown (4 tests)
| Test ID | Description | Status |
|---------|-------------|--------|
| UNIT-025 | SIGTERM during idle triggers graceful shutdown | ✅ |
| UNIT-026 | SIGINT during idle triggers graceful shutdown | ✅ |
| UNIT-027 | Signal during job execution completes current job | ✅ |
| UNIT-028 | Shutdown logged correctly with graceful exit | ✅ |

### 1.7 Startup Validation (4 tests)
| Test ID | Description | Status |
|---------|-------------|--------|
| UNIT-029 | Missing rclone config causes fatal error | ✅ |
| UNIT-030 | Non-writable data directory causes fatal error | ✅ |
| UNIT-031 | Worker creates missing job directories on startup | ✅ |
| UNIT-032 | Health file created when worker ready | ✅ |

### 1.8 Configuration (2 tests)
| Test ID | Description | Status |
|---------|-------------|--------|
| UNIT-037 | IDLE_SLEEP_SEC affects polling interval | ✅ |
| UNIT-038 | IDLE_SLEEP_SEC defaults to 1 when not set | ✅ |

## Test Execution

Run all unit tests:
```bash
cd /Users/nineking/workspace/app/s3sweep
bats tests/unit/test_worker.bats
```

Run specific test:
```bash
bats tests/unit/test_worker.bats --filter "UNIT-001"
```

Run with verbose output:
```bash
bats tests/unit/test_worker.bats --verbose-run
```

## Dependencies
- **bats-core**: Test framework
- **jq**: JSON validation in tests
- **Mock rclone**: Located at `tests/unit/mocks/rclone`

## Test Helpers
- `tests/lib/helpers.sh`: Test environment setup, worker management
- `tests/lib/assertions.sh`: Assertion functions for validation

## Notes
- All tests use isolated temporary directories via `setup_test_env()`
- Mock rclone controlled via environment variables:
  - `MOCK_RCLONE_EXIT`: Exit code (default 0)
  - `MOCK_RCLONE_DELAY`: Delay in seconds (default 0)
  - `MOCK_RCLONE_CREATE_FILE`: Create output file (default 0)
  - `MOCK_RCLONE_LOG`: Log invocations to file
- Tests run worker script in background and verify state transitions
- Cleanup handled automatically via `cleanup_test_env()` in teardown
