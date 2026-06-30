#!/usr/bin/env bash

ROOT="$(cd "$(dirname "$0")" && pwd)"
export ROOT

IS_MACOS=false
[[ "$(uname)" == "Darwin" ]] && IS_MACOS=true

DC=(docker compose --project-directory "$ROOT")
CORE=(-f "$ROOT/docker/core/docker-compose.yml")
ALLOY_DC=(-f "$ROOT/docker/alloy/docker-compose.yml")
METRICS=(-f "$ROOT/docker/metrics/docker-compose.yml")

PIDFILE="$ROOT/.start.pids"
PIDS=()

cleanup() {
  echo ""
  echo "[start] 종료 중..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -f "$PIDFILE"
}
trap cleanup EXIT INT TERM HUP

kill_saved_pids() {
  [ -f "$PIDFILE" ] || return 0
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done < "$PIDFILE"
  rm -f "$PIDFILE"
}

CMD="${1:-up}"

case "$CMD" in
  down)
    kill_saved_pids && echo "[start] 백그라운드 프로세스 종료"
    "${DC[@]}" "${CORE[@]}" "${ALLOY_DC[@]}" "${METRICS[@]}" down
    exit 0
    ;;
  logs)
    "${DC[@]}" "${CORE[@]}" "${ALLOY_DC[@]}" "${METRICS[@]}" logs -f "${@:2}"
    exit 0
    ;;
  status)
    docker ps \
      --filter "name=loki" --filter "name=grafana" --filter "name=alloy" \
      --filter "name=prometheus" --filter "name=textfile-exporter" \
      --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    exit 0
    ;;
  up) ;;
  *)
    echo "사용법: $0 [up|down|logs|status]"
    exit 1
    ;;
esac

echo ""
echo "[start] 시작 모드를 선택하세요:"
echo "  1) 로그만          (Loki + Grafana + 로그 스트리밍)"
echo "  2) 로그 + 메트릭   (+ Prometheus + 메트릭 수집)"
echo "  3) 전체            (+ Alloy + 메트릭 수집)"
echo ""
read -rp "선택 [1-3]: " MODE

bg_run() {
  local label="$1" script="$2"
  if [ ! -f "$script" ]; then
    echo "[start] $label: 파일 없음 — 건너뜀 ($script)"
    return
  fi
  echo "[start] $label 시작..."
  "$script" &
  PIDS+=($!)
}

case "$MODE" in
  1)
    "${DC[@]}" "${CORE[@]}" up -d
    echo ""
    echo "[start] Grafana: http://localhost:${GRAFANA_PORT:-3000}"
    echo ""
    bg_run "로그 스트리밍" "$ROOT/scripts/stream-logs.sh"
    ;;
  2)
    "${DC[@]}" "${CORE[@]}" "${METRICS[@]}" up -d
    echo ""
    echo "[start] Grafana:    http://localhost:${GRAFANA_PORT:-3000}"
    echo "[start] Prometheus: http://localhost:${PROMETHEUS_PORT:-9090}"
    echo ""
    bg_run "로그 스트리밍"  "$ROOT/scripts/stream-logs.sh"
    bg_run "메트릭 수집"    "$ROOT/scripts/collect-metrics.sh"
    ;;
  3)
    if $IS_MACOS; then
      "${DC[@]}" "${CORE[@]}" "${METRICS[@]}" up -d
      bg_run "Alloy (호스트)" "$ROOT/start-alloy.sh"
    else
      "${DC[@]}" "${CORE[@]}" "${ALLOY_DC[@]}" "${METRICS[@]}" up -d
    fi
    echo ""
    echo "[start] Grafana:    http://localhost:${GRAFANA_PORT:-3000}"
    echo "[start] Alloy:      http://localhost:12345"
    echo "[start] Prometheus: http://localhost:${PROMETHEUS_PORT:-9090}"
    echo ""
    bg_run "로그 스트리밍"  "$ROOT/scripts/stream-logs.sh"
    bg_run "메트릭 수집"    "$ROOT/scripts/collect-metrics.sh"
    ;;
  *)
    echo "[error] 1-3 중 선택하세요"
    exit 1
    ;;
esac

printf '%s\n' "${PIDS[@]}" > "$PIDFILE"

echo ""
echo "[start] 실행 중 (종료: Ctrl+C | Docker 유지 후 종료: Ctrl+C 다음 ./start.sh down)"
wait
