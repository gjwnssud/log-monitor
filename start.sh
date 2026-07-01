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
    cat <<EOF
사용법: $0 [up|down|logs|status]

  up      (기본값) 모드를 선택해 서비스를 시작합니다.
  down    up으로 시작한 백그라운드 프로세스(로그 스트리밍/메트릭 수집)와
          Docker 컨테이너를 모두 종료합니다.
  logs    현재 구성된 Docker 컨테이너의 로그를 실시간으로 봅니다.
  status  loki/grafana/alloy/prometheus/textfile-exporter 컨테이너 상태를 봅니다.
EOF
    exit 1
    ;;
esac

echo ""
echo "[start] 시작 모드를 선택하세요:"
echo ""
echo "  1) 로그만"
echo "     - Docker: Loki(로그 저장) + Grafana(대시보드) + Alloy(라벨링·인덱싱, macOS는 호스트에서 직접 실행)"
echo "     - 백그라운드: scripts/stream-logs.sh (SSH로 원격 로그 수집)"
echo ""
echo "  2) 로그 + 메트릭"
echo "     - Docker: 1번 + Prometheus(메트릭 저장) + textfile-exporter"
echo "     - 백그라운드: 1번 + scripts/collect-metrics.sh (CPU/메모리 등 수집)"
echo ""
read -rp "선택 [1-2]: " MODE

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

# Alloy: Linux는 Docker 컨테이너로 이미 up -d에 포함, macOS는 Docker 파일 감시 한계로 호스트에서 직접 실행
start_alloy() {
  $IS_MACOS && bg_run "Alloy (호스트)" "$ROOT/scripts/start-alloy.sh"
}

docker_up() {
  if $IS_MACOS; then
    "${DC[@]}" "${CORE[@]}" "$@" up -d
  else
    "${DC[@]}" "${CORE[@]}" "${ALLOY_DC[@]}" "$@" up -d
  fi
}

case "$MODE" in
  1)
    docker_up
    echo ""
    echo "[start] Grafana: http://localhost:${GRAFANA_PORT:-3000}"
    echo "[start] Alloy:   http://localhost:12345"
    echo ""
    bg_run "로그 스트리밍" "$ROOT/scripts/stream-logs.sh"
    start_alloy
    ;;
  2)
    docker_up "${METRICS[@]}"
    echo ""
    echo "[start] Grafana:    http://localhost:${GRAFANA_PORT:-3000}"
    echo "[start] Alloy:      http://localhost:12345"
    echo "[start] Prometheus: http://localhost:${PROMETHEUS_PORT:-9090}"
    echo ""
    bg_run "로그 스트리밍"  "$ROOT/scripts/stream-logs.sh"
    bg_run "메트릭 수집"    "$ROOT/scripts/collect-metrics.sh"
    start_alloy
    ;;
  *)
    echo "[error] 1-2 중 선택하세요"
    exit 1
    ;;
esac

printf '%s\n' "${PIDS[@]}" > "$PIDFILE"

echo ""
echo "[start] 실행 중 (종료: Ctrl+C | Docker 유지 후 종료: Ctrl+C 다음 ./start.sh down)"
wait
