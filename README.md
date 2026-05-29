# log-monitor

여러 원격 서버의 로그를 SSH 스트리밍으로 수집하여 Grafana 대시보드에서 실시간으로 모니터링하는 템플릿입니다.
원격 서버에 별도 에이전트를 설치할 수 없는 환경에서도 사용할 수 있습니다.

## 구성

```
원격 서버 (journalctl)
    ↓ SSH 스트리밍
data/logs/*.log (로컬)
    ↓
Promtail (로그 수집)
    ↓
Loki (로그 저장)
    ↓
Grafana (시각화) → http://localhost:3000
```

## 기술 스택

| 역할 | 기술 |
|------|------|
| 로그 수집 | [Promtail](https://grafana.com/docs/loki/latest/send-data/promtail/) |
| 로그 저장 | [Grafana Loki](https://grafana.com/oss/loki/) |
| 시각화 | [Grafana](https://grafana.com/oss/grafana/) |
| 컨테이너 | Docker Compose |
| 로그 전송 | SSH + journalctl |

## 사전 요구사항

- Docker Desktop
- 원격 서버 SSH 접근 권한 (`~/.ssh/config` 설정 권장)
- 원격 서버가 `systemd` 기반일 것 (journalctl 사용)

## 사용법

### 1. 설정 파일 준비

```bash
# 서버 목록 설정
cp servers.conf.example servers.conf

# 환경 변수 설정 (포트, 리소스 조정 필요 시)
cp .env.example .env
```

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

### 2. 초기화

```bash
./setup.sh
```

- `.env` 파일 자동 생성 (없을 경우)
- `data/` 디렉토리 생성
- `servers.conf` 기반으로 `promtail-config.yml` 자동 생성

### 3. 컨테이너 실행

```bash
docker compose up -d
```

### 4. SSH 로그 스트리밍 시작

```bash
./stream-logs.sh
```

- `servers.conf`의 각 서버에 SSH 접속 후 로그 스트리밍
- `data/logs/{alias}.log` 파일로 저장
- `Ctrl+C`로 종료

### 5. Grafana 접속

브라우저에서 `http://localhost:3000` 접속 후:

1. **Connections → Add new data source → Loki** 선택
2. URL: `http://loki:3100` 입력 후 저장
3. **Explore** 메뉴에서 `{job="logs"}` 쿼리로 로그 확인
4. 서버별 필터: `{server="server-1"}`

## 디렉토리 구조

```
log-monitor/
├── .env.example                  # 포트·리소스 설정 예시
├── servers.conf.example          # 서버 목록 예시
├── docker-compose.yml            # 컨테이너 구성
├── promtail-config.template.yml  # Promtail 설정 템플릿
├── setup.sh                      # 초기화 스크립트
├── stream-logs.sh                # SSH 스트리밍 스크립트
└── data/                         # 볼륨 데이터 (gitignore)
    ├── loki/
    ├── grafana/
    └── logs/
```

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

- `stream-logs.sh` 종료 시 SSH 연결이 끊겨 로그 수집이 중단됩니다. 데몬으로 운영하려면 `tmux` 또는 `screen` 세션 내에서 실행하세요.
- `servers.conf`와 `.env`는 보안 정보가 포함될 수 있으므로 git에 포함되지 않습니다.
