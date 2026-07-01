# log-monitor

여러 원격 서버의 log4j2 형식 Spring Boot 로그와 리소스(CPU/메모리/네트워크/디스크)를 수집해
Grafana 대시보드에서 실시간 모니터링하고, 장애 발생 시 Telegram으로 알림을 받는 템플릿입니다.
원격 서버에 별도 에이전트를 설치할 수 없는 환경에서도 사용할 수 있습니다.

## 구성

```
원격 서버 (journalctl)
    ↓ SSH 스트리밍 (scripts/stream-logs.sh)
data/logs/*.log (로컬)
    ↓
Alloy (로그 수집 + level/timestamp 라벨 추출)
    ↓
Loki (로그 저장) → Grafana (시각화) → http://localhost:3000
    ↓                                      ↑
Grafana Alerting (FATAL/ERROR 감지) ──→ Telegram 알림

원격 서버 (/proc, df 등)
    ↓ SSH 폴링 (scripts/collect-metrics.sh)
data/metrics/*.prom (로컬)
    ↓
textfile-exporter → Prometheus → Grafana
```

### OS별 Alloy 실행 방식

| OS | Alloy 실행 | 이유 |
|----|-----------|------|
| **Linux** | Docker 컨테이너 (`./start.sh` 실행 시 자동 포함) | inotify 정상 작동 |
| **macOS** | 호스트 직접 실행 (`./start.sh`가 `scripts/start-alloy.sh` 자동 실행) | Docker Desktop(VirtioFS/gRPC FUSE)에서 파일 이벤트가 컨테이너로 전달되지 않아 실시간 수집 불가 |
| **Windows** | 호스트 직접 실행 (`start.bat`이 `scripts\start-alloy.bat`을 새 창으로 자동 실행) | Docker Desktop(WSL2)에서 9P 브릿지 경유 시 동일 문제 발생 |

## 기술 스택

| 역할 | 기술 |
|------|------|
| 로그 수집 | [Grafana Alloy](https://grafana.com/docs/alloy/) |
| 로그 저장 | [Grafana Loki](https://grafana.com/oss/loki/) |
| 메트릭 저장 | [Prometheus](https://prometheus.io/) + node-exporter(textfile 모드) |
| 시각화·알림 | [Grafana](https://grafana.com/oss/grafana/) (Alerting → Telegram) |
| 컨테이너 | Docker Compose |
| 로그·메트릭 전송 | SSH + journalctl / `/proc` 폴링 |

## 사전 요구사항

- Docker Desktop
- 원격 서버 SSH 접근 권한 (`~/.ssh/config` 설정 권장)
- 원격 서버가 `systemd` 기반일 것 (journalctl 사용)
- **macOS**: Alloy (`brew install grafana/grafana/alloy`)
- **Windows**: Alloy (`winget install Grafana.Alloy`)
- **Linux**: 별도 설치 불필요 (Alloy가 Docker 컨테이너로 실행됨)

---

## 빠른 시작

### 1. 설정 파일 준비

```bash
cp servers.conf.example servers.conf   # 모니터링할 서버 목록
cp .env.example .env                   # 포트·리소스·Telegram 알림 설정
```

Windows는 `copy`로 동일하게 복사합니다.

### 2. 초기화

```bash
./setup.sh     # macOS/Linux
setup.bat      # Windows
```

실행 시 Alloy 수집 방식을 선택합니다 (원격 서버에 설치 권한이 없다면 1번 권장):

```
[setup] Alloy 수집 방식을 선택하세요:
  1) SSH 스트리밍       (서버 설치 권한 없음, scripts/stream-logs.sh 사용)
  2) Journal 직접 읽기  (서버에 Alloy 설치, systemd 서비스 로그)
  3) 파일 직접 읽기     (서버에 Alloy 설치, 파일 경로 지정)
```

- 1번(SSH 스트리밍) 선택 시 `config/alloy/alloy-config.alloy`와 함께, macOS/Windows에서는 `scripts/start-alloy.sh`(`.bat`)가 자동 생성됩니다.
- `.env`에 `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID`가 설정돼 있으면 Telegram 알림 연동 파일도 함께 생성됩니다 ([텔레그램 알림 설정](#텔레그램-알림-설정) 참고).
- 2번/3번(서버 직접 설치)은 [서버에 Alloy 직접 설치하는 경우](#서버에-alloy-직접-설치하는-경우)를 참고하세요.

### 3. Alloy 설치 (macOS/Windows, 최초 1회)

```bash
brew install grafana/grafana/alloy       # macOS
winget install Grafana.Alloy             # Windows
```

Linux는 Alloy가 Docker 컨테이너로 실행되므로 이 단계가 필요 없습니다.

### 4. 서비스 시작

```bash
./start.sh     # macOS/Linux
start.bat      # Windows
```

시작 모드를 선택합니다:

```
[start] 시작 모드를 선택하세요:

  1) 로그만
     - Docker: Loki(로그 저장) + Grafana(대시보드) + Alloy(라벨링·인덱싱, macOS/Windows는 호스트에서 직접 실행)
     - 백그라운드: scripts/stream-logs.sh (SSH로 원격 로그 수집)

  2) 로그 + 메트릭
     - Docker: 1번 + Prometheus(메트릭 저장) + textfile-exporter
     - 백그라운드: 1번 + scripts/collect-metrics.sh (CPU/메모리 등 수집)
```

두 모드 모두 로그 파이프라인(Alloy 포함)이 항상 함께 시작됩니다 — 메트릭 수집(Prometheus) 유무만 다릅니다.

- **macOS/Linux**: 선택 후 같은 터미널이 포그라운드로 유지되며 `Ctrl+C`로 종료합니다. Docker는 유지한 채 백그라운드 프로세스만 끄려면 `Ctrl+C` 후 `./start.sh down`을 실행하세요.
- **Windows**: 로그 스트리밍/메트릭 수집/Alloy가 각각 새 창으로 열립니다. 종료하려면 `start.bat down`을 실행하세요.

서브커맨드:

| 명령 | 설명 |
|------|------|
| `./start.sh` (또는 `up`) | 모드를 선택해 서비스 시작 (기본값) |
| `./start.sh down` | 백그라운드 프로세스와 Docker 컨테이너를 모두 종료 |
| `./start.sh logs` | 현재 실행 중인 Docker 컨테이너 로그를 실시간으로 확인 |
| `./start.sh status` | loki/grafana/alloy/prometheus/textfile-exporter 컨테이너 상태 확인 |

---

## 공통 설정

**servers.conf 형식:**
```
# alias  ssh-host  service-name
controller  bastion-host   my-controller-service
server-1    app-server-1   my-app-service
```

| 컬럼 | 설명 |
|------|------|
| alias | 로그 파일명 및 Grafana 라벨로 사용 (영문, 숫자, 하이픈) |
| ssh-host | `~/.ssh/config`에 등록된 Host명 또는 IP |
| service-name | `journalctl -u [service-name]`에 사용되는 systemd 서비스명 |

**로그 로테이션:**

스트리밍 중 파일 크기가 일정 기준을 초과하면 자동으로 rotate됩니다.
기본값은 `scripts/stream-logs.sh` / `scripts/stream-logs.ps1` 상단에서 변경할 수 있습니다.

| 설정 | 기본값 | 설명 |
|------|--------|------|
| `MAX_SIZE_MB` | 50 | 로테이션 기준 파일 크기 (MB) |
| `ROTATE_KEEP` | 5 | 보관할 로테이션 파일 개수 |
| `CHECK_INTERVAL` | 30 | 크기 체크 주기 (초) |

```
data/logs/
├── server-1.log      ← 현재 스트리밍 중
├── server-1.log.1    ← 가장 최근 rotate된 파일
├── server-1.log.2
└── ...
```

**메트릭 수집 (2번 모드):**

`scripts/collect-metrics.sh`가 SSH로 원격 서버의 `/proc/stat`, `/proc/meminfo`, `/proc/net/dev`, `df`를 주기적으로 폴링해
CPU 사용률(%), 메모리 사용률, 네트워크 RX/TX, 디스크 사용률을 `data/metrics/*.prom` 파일로 기록하고,
`textfile-exporter`가 이를 읽어 Prometheus에 노출합니다. 수집 주기는 `scripts/collect-metrics.sh` 상단 `INTERVAL`(초)에서 조정합니다.

---

## 텔레그램 알림 설정

FATAL 로그 발생, ERROR 급증 시 Grafana Alerting이 Telegram으로 알림을 보냅니다.

1. `.env`에 값 설정:
   ```
   TELEGRAM_BOT_TOKEN=<봇 토큰>
   TELEGRAM_CHAT_ID=<채팅방 ID>
   GRAFANA_EXTERNAL_URL=http://localhost:3000   # 알림 메시지의 대시보드 링크에 사용
   ```
2. `./setup.sh`(`setup.bat`)를 (다시) 실행 — `config/grafana/provisioning/alerting/contact-points.yml`, `templates.yml`이 생성됩니다.
3. `./start.sh`로 Grafana를 (재)시작하면 알림 규칙이 자동 프로비저닝됩니다.

기본 알림 규칙 (`config/grafana/provisioning/alerting/alert-rules.yml`):

| 규칙 | 조건 | 심각도 |
|------|------|--------|
| FATAL 로그 발생 | 최근 5분간 FATAL 1건 이상, 1분 지속 | critical |
| ERROR 급증 | 최근 5분간 ERROR 30건 초과, 5분 지속 | warning |

---

## Grafana 접속

브라우저에서 `http://localhost:3000` 접속 — Loki/Prometheus 데이터소스와 대시보드가 **자동으로 프로비저닝**됩니다.

- **로그 모니터링 대시보드**: Dashboards 메뉴 → `로그 모니터링`
- **서버 리소스 대시보드**: Dashboards 메뉴 → `서버 리소스` (2번 모드로 시작했을 때만 데이터가 채워짐)
- **직접 탐색**: Explore 메뉴 → `{job="logs"}` 쿼리로 전체 로그 확인
- **서버 필터**: `{job="logs", server="server-1"}`
- **에러만 보기**: `{job="logs", level="ERROR"}`

**Alloy UI:** `http://localhost:12345` — 컴포넌트 상태 및 로그 수집 현황 확인

### 로그 스트림 패널 활용 팁

| 목적 | 방법 |
|------|------|
| 최신 로그 보기 | 시간 범위를 `Last 5m` / `Last 15m` 등 짧게 설정 후 수동 새로고침(⟳) |
| 특정 시간대 탐색 | 시간 범위 피커에서 절대 시간 직접 지정 |
| 과거 로그 페이지네이션 | 우상단 **Explore** 아이콘(↗) → Explore 모드에서 Load More 지원 |
| 키워드 검색 | 상단 **로그 검색** 필터에 텍스트 입력 |

---

## 로그 모니터링 대시보드

`config/grafana/provisioning/dashboards/incident-response.json`에 정의된 대시보드가 자동 로드됩니다.

**🖥️ 서버 연결 상태**

| 패널 | 내용 |
|------|------|
| 서버별 로그 수신 이력 | 서버별 최근 로그 수신 시각 |

**🚨 에러 통계**

| 패널 | 내용 |
|------|------|
| ERROR / WARN / FATAL 건수 | 선택 기간 총 건수, 임계치 색상 표시 |
| Error/min (최근 5분) | 최근 5분 ERROR+FATAL 발생률 (건/분) |
| Error / Warn 추이 (레벨별) | ERROR / WARN / FATAL rate (건/분) over time |
| Error 추이 (서버별) | 서버별 ERROR+FATAL rate (건/분) over time |
| 서버별 로그 레벨 현황 | 서버 × 레벨 건수 테이블 (ERROR 기준 내림차순) |

**📋 실시간 로그**

| 패널 | 내용 |
|------|------|
| 로그 스트림 | 선택한 레벨·서버·검색어 기준 로그 (auto-refresh 없음, 수동 새로고침 또는 Explore 활용) |

### 상단 필터

| 필터 | 설명 |
|------|------|
| 서버 | 멀티셀렉, 특정 서버만 필터링 |
| 로그 레벨 | 멀티셀렉 (TRACE / DEBUG / INFO / WARN / ERROR / FATAL / All) |
| 로그 검색 | 자유 텍스트 입력, 로그 스트림에서 grep 방식으로 필터링 |

## 서버 리소스 대시보드

`config/grafana/provisioning/dashboards/resources.json`에 정의된 대시보드로, 2번 모드(로그+메트릭)로 시작했을 때만 데이터가 채워집니다.

| 섹션 | 패널 |
|------|------|
| 📈 CPU 사용률 | CPU 사용률 (%) |
| 💾 메모리 | 메모리 사용률 |
| 🌐 네트워크 | 수신 속도 (RX) / 송신 속도 (TX) |
| 💿 디스크 | 디스크 사용률 |

### UI에서 대시보드 수정

`allowUiUpdates: true` 설정으로 Grafana UI에서 직접 수정·저장이 가능합니다.
수정 내용은 Grafana 내부 DB(`data/grafana/`)에 저장되며, JSON 파일과는 별개로 관리됩니다.
JSON 파일에 반영하려면 UI에서 **Share → Export → Save to file** 후 파일을 교체하세요.

### log4j2 패턴이 다를 경우

Alloy 설정의 `loki.process "log4j2"` 블록에서 두 가지를 조정합니다.

**① 타임스탬프 추출 (`stage.regex` + `stage.timestamp`)**

로그 발생 시간을 정확히 Loki에 저장하기 위해 로그 라인에서 타임스탬프를 파싱합니다.

| 수집 방식 | 로그 포맷 | expression | format |
|---|---|---|---|
| SSH 스트리밍 (journald 출력) | `2026-01-01T12:00:00+09:00 host java[pid]: ...` | `` `^(?P<log_time>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2})` `` | `RFC3339` |
| 파일 직접 읽기 (log4j2 파일) | `[2026-01-01T12:00:00,123] [ERROR] ...` | `` `^\[(?P<log_time>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})` `` | `2006-01-02T15:04:05` |
| journal 직접 읽기 | — | 불필요 (systemd 타임스탬프 자동 사용) | — |

**② 레벨 추출 (`stage.regex` + `stage.labels`)**

| log4j2 패턴 | 출력 예시 | expression |
|---|---|---|
| `[%p]` (기본값) | `[ERROR]` | `` `\[(?P<level>TRACE\|DEBUG\|INFO\|WARN\|ERROR\|FATAL)\]` `` |
| `%-5level` | `ERROR ` | `` `\b(?P<level>TRACE\|DEBUG\|INFO\|WARN\|ERROR\|FATAL)\b` `` |

수정 대상 파일: `config/alloy/alloy-config.host.template.alloy`, `config/alloy/alloy-config.template.alloy`, `config/alloy/alloy-config-file.template.alloy`, `config/alloy/alloy-config-journal.template.alloy`

---

## 데이터 초기화 (재수집)

기존에 수집된 로그를 지우고 처음부터 다시 수집하려면:

```bash
./start.sh down                              # macOS/Linux (Windows는 start.bat down)
rm -rf data/loki data/alloy data/grafana
./start.sh                                    # 다시 모드 선택 후 시작
```

> `data/logs/`는 원본 로그 파일이므로 삭제하지 않습니다.

---

## 디렉토리 구조

```
log-monitor/
├── .env.example                              # 포트·리소스·Telegram 설정 예시
├── servers.conf.example                      # 서버 목록 예시
├── setup.sh / setup.bat                       # 초기화 스크립트 (macOS/Linux, Windows)
├── start.sh / start.bat                       # 시작/종료/로그/상태 스크립트 (macOS/Linux, Windows)
├── docker/
│   ├── core/docker-compose.yml               # Loki + Grafana (전 OS 공통)
│   ├── alloy/docker-compose.yml               # Alloy 컨테이너 (Linux 전용, start.sh가 자동 선택)
│   └── metrics/docker-compose.yml             # Prometheus + textfile-exporter (2번 모드)
├── scripts/
│   ├── stream-logs.sh / .ps1 / .bat           # SSH 로그 스트리밍 + 로테이션
│   ├── collect-metrics.sh / .ps1              # SSH 메트릭 폴링 + 로테이션
│   └── start-alloy.sh / .bat                  # macOS/Windows용 Alloy 호스트 실행 스크립트 (setup 시 자동 생성, gitignore)
├── config/
│   ├── loki.yml                               # Loki 설정 (flush 주기 등)
│   ├── prometheus.yml                         # Prometheus 스크레이프 설정
│   ├── alloy/
│   │   ├── alloy-config.host.template.alloy   # 템플릿 — macOS/Windows 호스트용
│   │   ├── alloy-config.template.alloy        # 템플릿 — Linux Docker용
│   │   ├── alloy-config-journal.template.alloy # 템플릿 — 서버 설치 (systemd journal)
│   │   ├── alloy-config-file.template.alloy   # 템플릿 — 서버 설치 (파일 직접 읽기)
│   │   └── alloy-config.alloy                 # setup 시 생성되는 실제 설정 (gitignore)
│   └── grafana/provisioning/
│       ├── datasources/                       # Loki/Prometheus 데이터소스 자동 등록
│       ├── dashboards/                        # incident-response.json(로그), resources.json(리소스)
│       └── alerting/                          # alert-rules.yml, notification-policies.yml,
│                                               #   contact-points.yml/templates.yml (setup 시 생성, gitignore)
└── data/                                      # 볼륨 데이터 (gitignore)
    ├── loki/ grafana/ prometheus/ alloy/ logs/ metrics/
```

---

## 서버에 Alloy 직접 설치하는 경우

원격 서버에 설치 권한이 있다면 SSH 스트리밍 없이 각 서버에서 직접 journal을 읽어 Loki로 전송할 수 있습니다.
`max_age` 설정으로 Alloy 시작 이전 로그도 소급 수집이 가능합니다.

### 1. 각 서버에 Alloy 설치

```bash
# Linux (AMD64)
curl -L https://github.com/grafana/alloy/releases/latest/download/alloy-linux-amd64.zip -o alloy.zip
unzip alloy.zip && chmod +x alloy-linux-amd64
```

### 2. 설정 파일 복사 및 수정

```bash
cp config/alloy/alloy-config-journal.template.alloy /etc/alloy/config.alloy
```

`config.alloy`에서 두 곳 수정:
- `SERVER_ALIAS` → 이 서버를 식별할 이름 (예: `edge-1`)
- `LOKI_HOST` → 중앙 Loki 서버 IP (예: `192.168.0.10`)

### 3. 실행

```bash
./alloy-linux-amd64 run /etc/alloy/config.alloy
```

### 템플릿 선택 기준

| | SSH 스트리밍 | 서버 설치 (journal) | 서버 설치 (file) |
|--|--|--|--|
| 서버 설치 권한 | 불필요 | 필요 | 필요 |
| 대상 로그 | journalctl | systemd 서비스 | 파일 경로 직접 지정 |
| 과거 로그 소급 | 불가 | 가능 (`max_age`) | 부분 가능 (`*.log*`) |
| 파일 로테이션 | 수동 필요 | 불필요 | inode 기반 자동 처리 |
| 안정성 | SSH 연결에 의존 | 서버 데몬 | 서버 데몬 |

---

## SSH 점프 호스트 설정

내부망 서버 접근 시 `~/.ssh/config`에 ProxyJump 설정:

```
Host bastion
    HostName [점프서버 IP]
    User [계정]
    IdentityFile ~/.ssh/your-key.pem

Host app-server-1
    HostName [서버 IP]
    User [계정]
    ProxyJump bastion
```

## 주의사항

- `./start.sh`(`start.bat`) 실행 중인 터미널/창을 닫으면 SSH 연결이 끊겨 로그·메트릭 수집이 중단됩니다. 백그라운드로 오래 유지하려면 `tmux`/`screen` 세션 내에서 실행하세요.
- `servers.conf`와 `.env`는 보안 정보가 포함될 수 있으므로 git에 포함되지 않습니다.
