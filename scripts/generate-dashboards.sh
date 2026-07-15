#!/usr/bin/env bash
# servers.conf의 group 컬럼별로 resources.json/incident-response.json 사본을 만들어
# config/grafana/provisioning/dashboards/<group>/ 에 생성한다 (전체 대시보드 2개는 그대로 유지).
#
# JSON을 파싱하지 않고 sed 텍스트 치환만 쓴다. 파일 안에서 JSON 문자열 값 내부에 이스케이프된
# 큰따옴표(원본 바이트로는 \" 2바이트)를 매칭/치환할 때는, sed 쪽 패턴/치환문에는 백슬래시를
# 2개(\\)로 적어야 "리터럴 백슬래시 1개"로 해석된다. 그래서 원본의 \" 자리는 이 스크립트에서
# \\" (백슬래시 2개 + 따옴표, 총 3글자)로 적는다.
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
DASH_DIR="$ROOT/config/grafana/provisioning/dashboards"
SERVERS_CONF="$ROOT/servers.conf"

if [ ! -f "$SERVERS_CONF" ]; then
  echo "[generate-dashboards] servers.conf 없음 → 그룹별 대시보드 생성 건너뜀 (전체 대시보드만 사용)"
  exit 0
fi

# 1) servers.conf에서 distinct group 목록 추출 (등장 순서 유지)
# 변수명은 GROUPS를 피한다 — bash의 내장 특수변수 $GROUPS(현재 사용자의 유닉스 group id 목록)와
# 겹쳐서 빈 배열로 초기화해도 실제 GID 목록이 섞여 나오는 문제가 있었음 (macOS 기본 bash 3.2에서 확인).
SERVER_GROUPS=()
while IFS= read -r line || [ -n "$line" ]; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  read -r _ _ _ group <<< "$line"
  group="${group:-default}"
  is_new=1
  for g in "${SERVER_GROUPS[@]}"; do
    [ "$g" = "$group" ] && is_new=0 && break
  done
  [ "$is_new" -eq 1 ] && SERVER_GROUPS+=("$group")
done < "$SERVERS_CONF"

if [ "${#SERVER_GROUPS[@]}" -eq 0 ]; then
  echo "[generate-dashboards] servers.conf에 그룹이 없어 그룹별 대시보드를 생성하지 않습니다."
  exit 0
fi

# 2) 이전에 생성된 그룹 폴더 정리 (전체 대시보드 2개 파일은 DASH_DIR 바로 아래에 있어 영향 없음)
find "$DASH_DIR" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'
}

# group 값을 sed 치환문 우변에 안전하게 넣기 위한 이스케이프 (백슬래시 → & → 구분자 # 순서로)
sed_escape_replacement() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/#/\\#/g'
}

for group in "${SERVER_GROUPS[@]}"; do
  if ! [[ "$group" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "[generate-dashboards] 경고: group \"${group}\"에 영문/숫자/하이픈 이외의 문자가 있습니다." \
         "JSON 특수문자(\\, \", 등)가 섞이면 대시보드가 깨질 수 있으니 영문 kebab-case로 바꾸는 걸 권장합니다."
  fi

  slug=$(slugify "$group")
  [ -z "$slug" ] && slug="group"
  group_esc=$(sed_escape_replacement "$group")

  group_dir="$DASH_DIR/$group"
  mkdir -p "$group_dir"

  sed \
    -e 's#"uid": "server-resources"#"uid": "server-resources-'"${slug}"'"#' \
    -e 's#"title": "서버 리소스"#"title": "서버 리소스 - '"${group_esc}"'"#' \
    -e 's#label_values(server_cpu_usage_percent, server)#label_values(server_cpu_usage_percent{group=\\"'"${group_esc}"'\\"}, server)#' \
    -e 's#server=~\\"$server\\"#group=\\"'"${group_esc}"'\\",server=~\\"$server\\"#g' \
    -e 's#by (group, server)#by (server)#g' \
    -e 's#{{group}}/{{server}}#{{server}}#g' \
    "$DASH_DIR/resources.json" > "$group_dir/resources.json"

  sed \
    -e 's#"uid": "spring-boot-incident"#"uid": "spring-boot-incident-'"${slug}"'"#' \
    -e 's#"title": "로그 모니터링"#"title": "로그 모니터링 - '"${group_esc}"'"#' \
    -e 's#label_values({job=\\"logs\\"}, server)#label_values({job=\\"logs\\", group=\\"'"${group_esc}"'\\"}, server)#g' \
    -e 's#server=~\\"$server\\"#group=\\"'"${group_esc}"'\\",server=~\\"$server\\"#g' \
    -e 's#by (group, server)#by (server)#g' \
    -e 's#{{group}}/{{server}}#{{server}}#g' \
    "$DASH_DIR/incident-response.json" > "$group_dir/incident-response.json"

  echo "[generate-dashboards] ${group} 폴더 생성 완료 (resources.json, incident-response.json)"
done

echo "[generate-dashboards] 총 ${#SERVER_GROUPS[@]}개 그룹 대시보드 생성 완료 (전체 대시보드는 그대로 유지)"
