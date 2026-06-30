#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

IS_MACOS=false
if [[ "$(uname)" == "Darwin" ]]; then
  IS_MACOS=true
fi

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
mkdir -p "$SCRIPT_DIR/data/metrics"
mkdir -p "$SCRIPT_DIR/data/prometheus"
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

    if $IS_MACOS; then
      TEMPLATE="$SCRIPT_DIR/alloy-config.host.template.alloy"
    else
      TEMPLATE="$SCRIPT_DIR/alloy-config.template.alloy"
    fi

    cp "$TEMPLATE" "$OUTPUT"

    if $IS_MACOS; then
      LOG_DIR="$SCRIPT_DIR/data/logs"
    else
      LOG_DIR="/logs"
    fi

    TEMP_FILE=$(mktemp)
    while IFS= read -r line || [ -n "$line" ]; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      read -r alias ssh_host service <<< "$line"
      echo "    {__path__ = \"${LOG_DIR}/${alias}.log\", job = \"logs\", server = \"${alias}\"}," >> "$TEMP_FILE"
    done < "$SCRIPT_DIR/servers.conf"

    sed -i.bak "s|// __SERVERS__|$(sed 's/[\/&]/\\&/g' "$TEMP_FILE" | tr '\n' '§' | sed 's/§/\\n/g')|" "$OUTPUT"
    rm -f "$TEMP_FILE" "${OUTPUT}.bak"

    echo "[setup] alloy-config.alloy 생성 완료 (SSH 스트리밍)"

    if $IS_MACOS; then
      START_ALLOY="$SCRIPT_DIR/start-alloy.sh"
      cat > "$START_ALLOY" <<EOF
#!/usr/bin/env bash
set -e
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
exec alloy run --storage.path "\$SCRIPT_DIR/data/alloy" "\$SCRIPT_DIR/alloy-config.alloy"
EOF
      chmod +x "$START_ALLOY"
      echo "[setup] start-alloy.sh 생성 완료"
      echo ""
      echo "[macOS] Alloy를 호스트에서 직접 실행합니다 (Docker 파일 감시 한계 우회)"
      echo ""
      echo "다음 단계:"
      echo "  1. Alloy 설치 (최초 1회):"
      echo "     brew install grafana/grafana/alloy"
      echo ""
      echo "  2. Docker 서비스 시작:"
      echo "     [로그만]       docker compose up -d"
      echo "     [로그+메트릭]  docker compose -f docker-compose.yml -f docker-compose.metrics.yml up -d"
      echo ""
      echo "  3. Alloy 실행 (새 터미널에서):"
      echo "     ./start-alloy.sh"
      echo ""
      echo "  4. 로그 스트리밍 시작 (새 터미널에서):"
      echo "     ./stream-logs.sh"
      echo ""
      echo "  5. [선택] 메트릭 수집 시작 (새 터미널에서):"
      echo "     ./collect-metrics.sh"
      echo ""
      echo "  6. 브라우저 접속:"
      echo "     Grafana: http://localhost:3000"
      echo "     Alloy:   http://localhost:12345"
    else
      echo ""
      echo "다음 단계:"
      echo "  [로그만]"
      echo "  1. docker compose -f docker-compose.yml -f docker-compose.alloy.yml up -d"
      echo "  2. ./stream-logs.sh"
      echo ""
      echo "  [로그+메트릭]"
      echo "  1. docker compose -f docker-compose.yml -f docker-compose.alloy.yml -f docker-compose.metrics.yml up -d"
      echo "  2. ./stream-logs.sh"
      echo "  3. ./collect-metrics.sh"
      echo ""
      echo "  브라우저 접속:"
      echo "    Grafana: http://localhost:3000"
      echo "    Alloy:   http://localhost:12345"
    fi
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

# Grafana alerting contact-points.yml 생성
generate_contact_points() {
  local template="$SCRIPT_DIR/grafana-provisioning/alerting/contact-points.yml.template"
  local output="$SCRIPT_DIR/grafana-provisioning/alerting/contact-points.yml"

  local bot_token chat_id
  bot_token=$(grep '^TELEGRAM_BOT_TOKEN=' "$SCRIPT_DIR/.env" | cut -d'=' -f2-)
  chat_id=$(grep '^TELEGRAM_CHAT_ID=' "$SCRIPT_DIR/.env" | cut -d'=' -f2-)

  if [ -z "$bot_token" ] || [ -z "$chat_id" ]; then
    echo "[setup] .env에 TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID 미설정 → contact-points.yml 생성 건너뜀"
    echo "        Telegram 알림을 사용하려면 .env에 값을 설정 후 setup.sh을 다시 실행하세요."
    return
  fi

  sed -e "s|__TELEGRAM_BOT_TOKEN__|${bot_token}|g" \
      -e "s|__TELEGRAM_CHAT_ID__|${chat_id}|g" \
      "$template" > "$output"

  echo "[setup] grafana-provisioning/alerting/contact-points.yml 생성 완료"
}

generate_contact_points
