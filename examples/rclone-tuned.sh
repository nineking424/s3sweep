RCLONE_CMD="rclone copy \
  ${SRC_ENDPOINT}:${SRC_PATH} \
  ${DST_DIR} \
  --config ${RCLONE_CONFIG} \
  --no-traverse \
  --s3-no-check-bucket \
  --s3-force-path-style \
  --s3-disable-checksum \
  --s3-chunk-size 16M \
  --transfers 1 \
  --checkers 1 \
  --multi-thread-streams 0 \
  --buffer-size 4M \
  --use-mmap \
  --tcp-keepalive 30s \
  --timeout 5m \
  --contimeout 15s \
  --low-level-retries 3 \
  --retries 1 \
  --retries-sleep 2s \
  --stats 0"

eval "${RCLONE_CMD}"
RC=$?
