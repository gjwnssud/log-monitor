# log-monitor

여러 원격 서버의 log4j2 형식 Spring Boot 로그를 수집하여 Grafana 대시보드에서 실시간으로 모니터링하는 템플릿입니다.
원격 서버에 별도 에이전트를 설치할 수 없는 환경에서도 사용할 수 있습니다.

## 구성

```
원격 서버 (journalctl)
    ↓ SSH 스트리밍
data/logs/*.log (로컬)
    ↓
Alloy (로그 수집 + level 라벨 추출)
    ↓
Loki (로그 저장)
    ↓
Grafana (시각화) → http://localhost:3000
  └─ 장애 대응 대시보드 자동 로드
```

## 기술 스택

| 역할 | 기술 |
|------|------|
| 로그 수집 | [Grafana Alloy](https://grafana.com/docs/alloy/) |
| 로그 저장 | [Grafana Loki](https://grafana.com/oss/loki/) |
| 시각화 | [Grafana](https://grafana.com/oss/grafana/) |
| 컨테이너 | Docker Compose |
| 로그 전송 | SSH + journalctl |

## 사전 요구사항

- Docker Desktop
- 원격 서버 SSH 접근 권한 (`~/.ssh/config` 설정 권장)
- 원격 서버가 `systemd` 기반일 것 (journalctl 사용)

---

## 사용법 — macOS / Linux

### 1. 설정 파일 준비

```bash
cp servers.conf.example servers.conf
# 필요 시 포트·리소스 조정
cp .env.example .env
```

### 2. 초기화

```bash
./setup.sh
```

실행 시 수집 방식을 선택합니다:

```
[setup] Alloy 수집 방식을 선택하세요:
  1) SSH 스트리밍       (서버 설치 권한 없음, stream-logs.sh 사용)
  2) Journal 직접 읽기  (서버에 Alloy 설치, systemd 서비스 로그)
  3) 파일 직접 읽기     (서버에 Alloy 설치, 파일 경로 지정)
```

### 3. 컨테이너 실행

```bash
docker compose up -d
```

### 4. SSH 로그 스트리밍 시작

```bash
./stream-logs.sh
# 백그라운드 실행
./stream-logs.sh &
```

---

## 사용법 — Windows

> Windows 10 이상 (OpenSSH, PowerShell 5.1+ 필요)

### 1. 설정 파일 준비

```bat
copy servers.conf.example servers.conf
copy .env.example .env
```

### 2. 초기화

```bat
setup.bat
```

실행 시 수집 방식을 선택합니다:

```
[setup] Alloy 수집 방식을 선택하세요:
  1) SSH 스트리밍       (서버 설치 권한 없음, stream-logs.bat 사용)
  2) Journal 직접 읽기  (서버에 Alloy 설치, systemd 서비스 로그)
  3) 파일 직접 읽기     (서버에 Alloy 설치, 파일 경로 지정)
```

### 3. 컨테이너 실행

```bat
docker compose up -d
```

### 4. SSH 로그 스트리밍 시작

```bat
stream-logs.bat
```

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
기본값은 `stream-logs.sh` / `stream-logs.ps1` 상단에서 변경할 수 있습니다.

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

---

## Grafana 접속

브라우저에서 `http://localhost:3000` 접속 — Loki 데이터소스와 대시보드가 **자동으로 프로비저닝**됩니다.

- **장애 대응 대시보드**: Dashboards 메뉴 → `Spring Boot 장애 대응`
- **직접 탐색**: Explore 메뉴 → `{job="logs"}` 쿼리로 전체 로그 확인
- **서버 필터**: `{job="logs", server="server-1"}`
- **에러만 보기**: `{job="logs", level="ERROR"}`

**Alloy UI:** `http://localhost:12345` — 컴포넌트 상태 및 로그 수집 현황 확인

---

## 장애 대응 대시보드

`grafana-provisioning/dashboards/incident-response.json`에 정의된 대시보드가 자동 로드됩니다.

| 패널 | 내용 |
|------|------|
| ERROR / WARN / FATAL 건수 | 선택 기간 총 건수, 임계치 색상 표시 |
| Error/min | 최근 5분 ERROR+FATAL 발생률 |
| 레벨별 추이 | ERROR / WARN / FATAL rate over time |
| 서버별 추이 | 서버별 ERROR rate over time |
| 장애 로그 스트림 | ERROR / WARN / FATAL 실시간 로그 |
| 서버별 현황 | 서버 × 레벨 건수 테이블 |

상단 **서버 드롭다운**으로 특정 서버만 필터링할 수 있습니다.

### log4j2 패턴이 다를 경우

Alloy 설정의 `stage.regex`에서 `expression`을 교체합니다:

| log4j2 패턴 | 출력 예시 | expression |
|---|---|---|
| `[%p]` (기본값) | `[ERROR]` | `` `\[(?P<level>TRACE\|DEBUG\|INFO\|WARN\|ERROR\|FATAL)\]` `` |
| `%-5level` | `ERROR ` | `` `\b(?P<level>TRACE\|DEBUG\|INFO\|WARN\|ERROR\|FATAL)\b` `` |

수정 대상 파일: `alloy-config.template.alloy`, `alloy-config-file.template.alloy`, `alloy-config-journal.template.alloy`

---

## 데이터 초기화 (재수집)

기존에 수집된 로그를 지우고 처음부터 다시 수집하려면:

```bash
docker compose down
rm -rf data/loki data/alloy data/grafana
docker compose up -d
```

> `data/logs/`는 원본 로그 파일이므로 삭제하지 않습니다.

---

## 디렉토리 구조

```
log-monitor/
├── .env.example                  # 포트·리소스 설정 예시
├── servers.conf.example          # 서버 목록 예시
├── docker-compose.yml            # 컨테이너 구성
├── alloy-config.template.alloy          # Alloy 설정 템플릿 (SSH 스트리밍 방식)
├── alloy-config-journal.template.alloy  # Alloy 설정 템플릿 (서버 설치 - systemd journal)
├── alloy-config-file.template.alloy     # Alloy 설정 템플릿 (서버 설치 - 파일 직접 읽기)
├── setup.sh                      # 초기화 스크립트 (macOS/Linux)
├── setup.bat                     # 초기화 스크립트 (Windows)
├── stream-logs.sh                # SSH 스트리밍 + 로테이션 (macOS/Linux)
├── stream-logs.bat               # SSH 스트리밍 진입점 (Windows)
├── stream-logs.ps1               # SSH 스트리밍 + 로테이션 (Windows PowerShell)
├── grafana-provisioning/         # Grafana 프로비저닝 설정
│   ├── datasources/
│   │   └── loki.yml              # Loki 데이터소스 자동 등록
│   └── dashboards/
│       ├── dashboards.yml        # 대시보드 파일 경로 등록
│       └── incident-response.json  # Spring Boot 장애 대응 대시보드
└── data/                         # 볼륨 데이터 (gitignore)
    ├── loki/
    ├── grafana/
    ├── alloy/
    └── logs/
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
cp alloy-config-journal.template.alloy /etc/alloy/config.alloy
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

- `stream-logs.sh` / `stream-logs.bat` 종료 시 SSH 연결이 끊겨 로그 수집이 중단됩니다. 백그라운드 또는 `tmux` 세션 내에서 실행하세요.
- `servers.conf`와 `.env`는 보안 정보가 포함될 수 있으므로 git에 포함되지 않습니다.
