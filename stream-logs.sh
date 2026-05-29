#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/data/logs"
PIDS=()

# 로그 로테이션 설정
MAX_SIZE_MB=50   # 로테이션 기준 파일 크기 (MB)
ROTATE_KEEP=5    # 보관할 로테이션 파일 개수
CHECK_INTERVAL=30  # 크기 체크 주기 (초)

# servers.conf 확인
if [ ! -f "$SCRIPT_DIR/servers.conf" ]; then
  echo "[error] servers.conf 파일이 없습니다."
  exit 1
fi

cleanup() {
  echo ""
  echo "[stream] 스트리밍 종료 중..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  echo "[stream] 종료 완료"
}
trap cleanup EXIT INT TERM

file_size_mb() {
  local file="$1"
  local size
  size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
  echo $(( size / 1024 / 1024 ))
}

rotate_log() {
  local file="$1"

  # 기존 로테이션 파일 시프트 (.4 → .5, .3 → .4, ...)
  for i in $(seq $(( ROTATE_KEEP - 1 )) -1 1); do
    [ -f "${file}.${i}" ] && mv "${file}.${i}" "${file}.$((i + 1))"
  done

  # 현재 파일 복사 후 원본 비우기 (스트리밍 프로세스 유지)
  cp "$file" "${file}.1"
  truncate -s 0 "$file"
  echo "[rotate] $(basename "$file") rotated (보관: ${file}.1)"
}

monitor_rotation() {
  while true; do
    sleep "$CHECK_INTERVAL"
    while IFS= read -r line || [ -n "$line" ]; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      read -r alias _ _ <<< "$line"
      local log_file="$LOG_DIR/${alias}.log"

      if [ -f "$log_file" ] && [ "$(file_size_mb "$log_file")" -ge "$MAX_SIZE_MB" ]; then
        rotate_log "$log_file"
      fi
    done < "$SCRIPT_DIR/servers.conf"
  done
}

echo "[stream] SSH 로그 스트리밍 시작"
echo ""

while IFS= read -r line || [ -n "$line" ]; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue

  read -r alias ssh_host service <<< "$line"
  log_file="$LOG_DIR/${alias}.log"

  echo "[stream] ${alias} → ${ssh_host} (${service})"
  ssh "$ssh_host" "journalctl -u ${service} -f --output=short-iso" >> "$log_file" &
  PIDS+=($!)
done < "$SCRIPT_DIR/servers.conf"

# 로테이션 모니터 백그라운드 실행
monitor_rotation &
PIDS+=($!)

echo ""
echo "[stream] 스트리밍 중... (종료: Ctrl+C)"
echo "[rotate] 로테이션 기준: ${MAX_SIZE_MB}MB, 보관: ${ROTATE_KEEP}개, 체크 주기: ${CHECK_INTERVAL}초"
wait
