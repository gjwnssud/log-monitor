#!/usr/bin/env bash
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
export ROOT

DC="docker compose --project-directory $ROOT"
CORE="-f $ROOT/modules/core/docker-compose.yml"
ALLOY="-f $ROOT/modules/alloy/docker-compose.yml"
METRICS="-f $ROOT/modules/metrics/docker-compose.yml"

CMD="${1:-up}"

case "$CMD" in
  down)
    $DC $CORE $ALLOY $METRICS down
    ;;
  logs)
    $DC $CORE $ALLOY $METRICS logs -f "${@:2}"
    ;;
  status)
    docker ps --filter "name=loki" --filter "name=grafana" --filter "name=alloy" \
              --filter "name=prometheus" --filter "name=textfile-exporter" \
              --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    ;;
  up)
    echo ""
    echo "[start] 시작 모드를 선택하세요:"
    echo "  1) 로그만          (Loki + Grafana)"
    echo "  2) 로그 + 메트릭   (+ Prometheus)"
    echo "  3) 전체            (+ Alloy Docker, Linux 전용)"
    echo ""
    read -rp "선택 [1-3]: " MODE

    case "$MODE" in
      1)
        $DC $CORE up -d
        echo ""
        echo "[start] 서비스 시작 완료"
        echo "  Grafana:  http://localhost:${GRAFANA_PORT:-3000}"
        echo ""
        echo "[start] 로그 스트리밍:"
        echo "  ./scripts/stream-logs.sh"
        ;;
      2)
        $DC $CORE $METRICS up -d
        echo ""
        echo "[start] 서비스 시작 완료"
        echo "  Grafana:     http://localhost:${GRAFANA_PORT:-3000}"
        echo "  Prometheus:  http://localhost:${PROMETHEUS_PORT:-9090}"
        echo ""
        echo "[start] 다음 단계 (새 터미널):"
        echo "  로그 스트리밍: ./scripts/stream-logs.sh"
        echo "  메트릭 수집:   ./scripts/collect-metrics.sh"
        ;;
      3)
        $DC $CORE $ALLOY $METRICS up -d
        echo ""
        echo "[start] 서비스 시작 완료"
        echo "  Grafana:     http://localhost:${GRAFANA_PORT:-3000}"
        echo "  Alloy:       http://localhost:12345"
        echo "  Prometheus:  http://localhost:${PROMETHEUS_PORT:-9090}"
        echo ""
        echo "[start] 다음 단계 (새 터미널):"
        echo "  로그 스트리밍: ./scripts/stream-logs.sh"
        echo "  메트릭 수집:   ./scripts/collect-metrics.sh"
        ;;
      *)
        echo "[error] 1-3 중 선택하세요"
        exit 1
        ;;
    esac
    ;;
  *)
    echo "사용법: $0 [up|down|logs|status]"
    exit 1
    ;;
esac
