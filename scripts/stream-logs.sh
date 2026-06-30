#!/usr/bin/env bash
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
LOG_DIR="$ROOT/data/logs"
PIDS=()

MAX_SIZE_MB=50
ROTATE_KEEP=5
CHECK_INTERVAL=30
RECONNECT_DELAY=5

if [ ! -f "$ROOT/servers.conf" ]; then
  echo "[error] servers.conf 파일이 없습니다."
  exit 1
fi

cleanup() {
  echo ""
  echo "[stream] 스트리밍 종료 중..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  echo "[stream] 종료 완료"
}
trap cleanup EXIT INT TERM HUP

file_size_mb() {
  local file="$1"
  local size
  size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
  echo $(( size / 1024 / 1024 ))
}

rotate_log() {
  local file="$1"
  for i in $(seq $(( ROTATE_KEEP - 1 )) -1 1); do
    [ -f "${file}.${i}" ] && mv "${file}.${i}" "${file}.$((i + 1))"
  done
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
    done < "$ROOT/servers.conf"
  done
}

stream_server() {
  local alias="$1"
  local ssh_host="$2"
  local service="$3"
  local log_file="$LOG_DIR/${alias}.log"
  local ssh_pid

  trap 'kill "$ssh_pid" 2>/dev/null; exit 0' TERM INT

  while true; do
    echo "[stream] ${alias} → ${ssh_host} (${service}) 연결 중..."
    ssh -o "ServerAliveInterval=10" -o "ServerAliveCountMax=3" -o "ConnectTimeout=10" \
        "$ssh_host" "journalctl -u ${service} -f --output=short-iso" >> "$log_file" &
    ssh_pid=$!
    wait "$ssh_pid" || true
    echo "[stream] ${alias} 연결 끊김. ${RECONNECT_DELAY}초 후 재연결..."
    sleep "$RECONNECT_DELAY"
  done
}

echo "[stream] SSH 로그 스트리밍 시작"
echo ""

while IFS= read -r line || [ -n "$line" ]; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue

  read -r alias ssh_host service <<< "$line"
  echo "[stream] ${alias} → ${ssh_host} (${service})"
  stream_server "$alias" "$ssh_host" "$service" &
  PIDS+=($!)
done < "$ROOT/servers.conf"

monitor_rotation &
PIDS+=($!)

echo ""
echo "[stream] 스트리밍 중... (종료: Ctrl+C)"
echo "[rotate] 로테이션 기준: ${MAX_SIZE_MB}MB, 보관: ${ROTATE_KEEP}개, 체크 주기: ${CHECK_INTERVAL}초"
echo "[reconnect] 재연결 대기: ${RECONNECT_DELAY}초 (SSH keepalive: 10s × 3회)"
wait
