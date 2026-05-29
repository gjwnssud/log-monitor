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
mkdir -p "$SCRIPT_DIR/data/alloy"
mkdir -p "$SCRIPT_DIR/data/logs"
echo "[setup] data/ 디렉토리 생성 완료"

# alloy-config.alloy 생성
TEMPLATE="$SCRIPT_DIR/alloy-config.template.alloy"
OUTPUT="$SCRIPT_DIR/alloy-config.alloy"

# 템플릿에서 __SERVERS__ 위치까지 복사
grep -v "// __SERVERS__" "$TEMPLATE" > "$OUTPUT"

# servers.conf 파싱하여 path_targets 항목 추가
TEMP_FILE=$(mktemp)
while IFS= read -r line || [ -n "$line" ]; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue

  read -r alias ssh_host service <<< "$line"

  echo "    {__path__ = \"/logs/${alias}.log\", job = \"logs\", server = \"${alias}\"}," >> "$TEMP_FILE"
done < "$SCRIPT_DIR/servers.conf"

# __SERVERS__ 자리에 삽입
sed -i.bak "s|// __SERVERS__|$(cat "$TEMP_FILE" | sed 's/[\/&]/\\&/g' | tr '\n' '§' | sed 's/§/\\n/g')|" "$OUTPUT"
rm -f "$TEMP_FILE" "${OUTPUT}.bak"

echo "[setup] alloy-config.alloy 생성 완료"
echo ""
echo "다음 단계:"
echo "  1. docker compose up -d"
echo "  2. ./stream-logs.sh"
echo "  3. 브라우저에서 http://localhost:3000 접속 (Grafana)"
echo "  4. 브라우저에서 http://localhost:12345 접속 (Alloy UI)"
