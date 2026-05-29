#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# .env 확인
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  echo "[setup] .env 파일 생성 완료 (.env.example 복사)"
fi

# servers.conf 확인 (SSH 스트리밍 방식에서만 필요)
check_servers_conf() {
  if [ ! -f "$SCRIPT_DIR/servers.conf" ]; then
    echo "[error] servers.conf 파일이 없습니다. servers.conf.example을 복사해 수정하세요."
    echo "  cp servers.conf.example servers.conf"
    exit 1
  fi
}

# 디렉토리 생성
mkdir -p "$SCRIPT_DIR/data/loki"
mkdir -p "$SCRIPT_DIR/data/grafana"
mkdir -p "$SCRIPT_DIR/data/alloy"
mkdir -p "$SCRIPT_DIR/data/logs"
echo "[setup] data/ 디렉토리 생성 완료"

# Alloy 수집 방식 선택
echo ""
echo "[setup] Alloy 수집 방식을 선택하세요:"
echo "  1) SSH 스트리밍       (서버 설치 권한 없음, stream-logs.sh 사용)"
echo "  2) Journal 직접 읽기  (서버에 Alloy 설치, systemd 서비스 로그)"
echo "  3) 파일 직접 읽기     (서버에 Alloy 설치, 파일 경로 지정)"
echo ""
read -rp "선택 [1-3]: " CHOICE

OUTPUT="$SCRIPT_DIR/alloy-config.alloy"

case "$CHOICE" in
  1)
    check_servers_conf
    TEMPLATE="$SCRIPT_DIR/alloy-config.template.alloy"

    cp "$TEMPLATE" "$OUTPUT"

    TEMP_FILE=$(mktemp)
    while IFS= read -r line || [ -n "$line" ]; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      read -r alias ssh_host service <<< "$line"
      echo "    {__path__ = \"/logs/${alias}.log\", job = \"logs\", server = \"${alias}\"}," >> "$TEMP_FILE"
    done < "$SCRIPT_DIR/servers.conf"

    sed -i.bak "s|// __SERVERS__|$(sed 's/[\/&]/\\&/g' "$TEMP_FILE" | tr '\n' '§' | sed 's/§/\\n/g')|" "$OUTPUT"
    rm -f "$TEMP_FILE" "${OUTPUT}.bak"

    echo "[setup] alloy-config.alloy 생성 완료 (SSH 스트리밍)"
    echo ""
    echo "다음 단계:"
    echo "  1. docker compose up -d"
    echo "  2. ./stream-logs.sh"
    echo "  3. 브라우저에서 http://localhost:3000 접속 (Grafana)"
    echo "  4. 브라우저에서 http://localhost:12345 접속 (Alloy UI)"
    ;;
  2)
    cp "$SCRIPT_DIR/alloy-config-journal.template.alloy" "$OUTPUT"
    echo "[setup] alloy-config.alloy 생성 완료 (Journal 직접 읽기)"
    echo ""
    echo "다음 단계:"
    echo "  1. alloy-config.alloy 에서 SERVER_ALIAS, LOKI_HOST 수정"
    echo "  2. 각 서버에 Alloy 설치 후 config 배포"
    ;;
  3)
    cp "$SCRIPT_DIR/alloy-config-file.template.alloy" "$OUTPUT"
    echo "[setup] alloy-config.alloy 생성 완료 (파일 직접 읽기)"
    echo ""
    echo "다음 단계:"
    echo "  1. alloy-config.alloy 에서 SERVER_ALIAS, LOKI_HOST, 로그 경로 수정"
    echo "  2. 각 서버에 Alloy 설치 후 config 배포"
    ;;
  *)
    echo "[error] 올바른 번호를 입력하세요 (1-3)"
    exit 1
    ;;
esac
