#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/data/logs"
PIDS=()

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

echo ""
echo "[stream] 스트리밍 중... (종료: Ctrl+C)"
wait
