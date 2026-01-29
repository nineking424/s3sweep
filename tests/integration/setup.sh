#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BUCKET="s3sweep-test"
MINIO_ENDPOINT="http://localhost:9000"
MINIO_USER="minioadmin"
MINIO_PASSWORD="minioadmin"

echo "Waiting for MinIO to be ready..."
for i in {1..30}; do
  if curl -sf "${MINIO_ENDPOINT}/minio/health/live" > /dev/null 2>&1; then
    echo "MinIO is ready"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "ERROR: MinIO failed to start after 30 seconds"
    exit 1
  fi
  echo "Attempt $i/30: MinIO not ready yet..."
  sleep 1
done

# Configure MinIO client
echo "Configuring MinIO client..."
mc alias set s3sweep-local "${MINIO_ENDPOINT}" "${MINIO_USER}" "${MINIO_PASSWORD}"

# Create test bucket
echo "Creating test bucket: ${TEST_BUCKET}"
mc mb "s3sweep-local/${TEST_BUCKET}" --ignore-existing

# Generate test files of various sizes
echo "Generating test files..."
mkdir -p "${SCRIPT_DIR}/testdata"

# 1KB file
dd if=/dev/urandom of="${SCRIPT_DIR}/testdata/file_1kb.bin" bs=1024 count=1 2>/dev/null
echo "Generated 1KB test file"

# 1MB file
dd if=/dev/urandom of="${SCRIPT_DIR}/testdata/file_1mb.bin" bs=1048576 count=1 2>/dev/null
echo "Generated 1MB test file"

# 100MB file
dd if=/dev/urandom of="${SCRIPT_DIR}/testdata/file_100mb.bin" bs=1048576 count=100 2>/dev/null
echo "Generated 100MB test file"

# Small text file for easy verification
echo "This is a test file for s3sweep" > "${SCRIPT_DIR}/testdata/test.txt"

# Upload test files to MinIO
echo "Uploading test files to MinIO..."
mc cp "${SCRIPT_DIR}/testdata/file_1kb.bin" "s3sweep-local/${TEST_BUCKET}/test/file_1kb.bin"
mc cp "${SCRIPT_DIR}/testdata/file_1mb.bin" "s3sweep-local/${TEST_BUCKET}/test/file_1mb.bin"
mc cp "${SCRIPT_DIR}/testdata/file_100mb.bin" "s3sweep-local/${TEST_BUCKET}/test/file_100mb.bin"
mc cp "${SCRIPT_DIR}/testdata/test.txt" "s3sweep-local/${TEST_BUCKET}/test/test.txt"

# Generate rclone config for testing
echo "Generating rclone test configuration..."
cat > "${SCRIPT_DIR}/rclone.conf" <<EOF
[s3test]
type = s3
provider = Minio
env_auth = false
access_key_id = ${MINIO_USER}
secret_access_key = ${MINIO_PASSWORD}
endpoint = ${MINIO_ENDPOINT}
EOF

echo "Test environment setup complete!"
echo "MinIO Console: http://localhost:9001 (user: ${MINIO_USER}, password: ${MINIO_PASSWORD})"
echo "Test bucket: ${TEST_BUCKET}"
echo "Rclone config: ${SCRIPT_DIR}/rclone.conf"
