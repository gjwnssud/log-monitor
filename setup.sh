#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# .env 확인
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  echo "[setup] .env 파일 생성 완료 (.env.example 복사)"
fi

# servers.conf 확인
if [ ! -f "$SCRIPT_DIR/servers.conf" ]; then
  echo "[error] servers.conf 파일이 없습니다. servers.conf.example을 복사해 수정하세요."
  echo "  cp servers.conf.example servers.conf"
  exit 1
fi

# 디렉토리 생성
mkdir -p "$SCRIPT_DIR/data/loki"
mkdir -p "$SCRIPT_DIR/data/grafana"
mkdir -p "$SCRIPT_DIR/data/logs"
echo "[setup] data/ 디렉토리 생성 완료"

# promtail-config.yml 생성
TEMPLATE="$SCRIPT_DIR/promtail-config.template.yml"
OUTPUT="$SCRIPT_DIR/promtail-config.yml"

# 템플릿에서 __SERVERS__ 위치까지 복사
grep -v "# __SERVERS__" "$TEMPLATE" > "$OUTPUT"

# servers.conf 파싱하여 항목 추가
while IFS= read -r line || [ -n "$line" ]; do
  # 빈 줄, 주석 건너뜀
  [[ -z "$line" || "$line" =~ ^# ]] && continue

  read -r alias ssh_host service <<< "$line"

  cat >> "$OUTPUT" << EOF
      - targets: [localhost]
        labels:
          job: logs
          server: ${alias}
          __path__: /logs/${alias}.log
EOF
done < "$SCRIPT_DIR/servers.conf"

echo "[setup] promtail-config.yml 생성 완료"
echo ""
echo "다음 단계:"
echo "  1. docker compose up -d"
echo "  2. ./stream-logs.sh"
echo "  3. 브라우저에서 http://localhost:3000 접속"
