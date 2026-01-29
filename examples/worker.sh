#!/usr/bin/env bash
set -euo pipefail

############################################
# 기본 설정
############################################

# StatefulSet Pod 이름 기반 Worker ID
HOSTNAME=$(hostname)
WORKER_ID=${HOSTNAME##*-}
TOTAL_WORKERS=${TOTAL_WORKERS:-1}

# rclone 바이너리
RCLONE_BIN=${RCLONE_BIN:-/usr/bin/rclone}

# ConfigMap으로 주입된 rclone config
RCLONE_CONFIG=${RCLONE_CONFIG:-/etc/rclone/rclone.conf}

# 작업이 없을 때 대기 시간 (초)
IDLE_SLEEP_SEC=1

############################################
# 로깅
############################################
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [worker=${WORKER_ID}] $*"
}

############################################
# 작업 가져오기
# 이 함수만 환경에 맞게 구현
############################################
fetch_jobs() {
  # 반환 형식 (한 줄 = 한 작업)
  # job_id|remote_name|src_path|dst_path
  #
  # remote_name:
  #   rclone.conf 에 정의된 remote (예: s3a, s3b, s3_custom_01)
  #
  # src_path:
  #   bucket/path/file
  #
  # dst_path:
  #   /local/path/file

  # ---- 예시 mock (실환경에서는 제거) ----
  return 1
}

############################################
# 작업 결과 전송
############################################
send_result() {
  local job_id="$1"
  local status="$2"
  local elapsed_ms="$3"
  local message="$4"

  # DB update / API call / Queue publish 등으로 교체
  log "RESULT job_id=${job_id} status=${status} elapsed_ms=${elapsed_ms} msg=${message}"
}

############################################
# 단일 작업 처리
############################################
process_job() {
  local job_line="$1"

  IFS='|' read -r \
    job_id \
    remote \
    src_path \
    dst_path <<< "${job_line}"

  log "START job_id=${job_id} remote=${remote} src=${src_path} dst=${dst_path}"

  local start_ts
  start_ts=$(date +%s%3N)

  set +e
  "${RCLONE_BIN}" copyto \
    "${remote}:${src_path}" \
    "${dst_path}" \
    --config "${RCLONE_CONFIG}" \
    --no-check-dest \
    --ignore-size \
    --retries 3 \
    --low-level-retries 1 \
    --stats 0 \
    --log-level ERROR
  rc=$?
  set -e

  local end_ts
  end_ts=$(date +%s%3N)
  local elapsed_ms=$((end_ts - start_ts))

  if [ "${rc}" -eq 0 ]; then
    send_result "${job_id}" "SUCCESS" "${elapsed_ms}" ""
    log "DONE job_id=${job_id} SUCCESS"
  else
    send_result "${job_id}" "FAILED" "${elapsed_ms}" "rclone_exit_code=${rc}"
    log "DONE job_id=${job_id} FAILED rc=${rc}"
  fi
}

############################################
# 메인 루프
############################################
log "Worker started (worker_id=${WORKER_ID}, total_workers=${TOTAL_WORKERS})"
log "Using rclone config: ${RCLONE_CONFIG}"

while true; do
  jobs=$(fetch_jobs || true)

  if [ -z "${jobs}" ]; then
    sleep "${IDLE_SLEEP_SEC}"
    continue
  fi

  while IFS= read -r job_line; do
    [ -z "${job_line}" ] && continue
    process_job "${job_line}"
  done <<< "${jobs}"

done
