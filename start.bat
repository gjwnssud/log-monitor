@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

set SCRIPT_DIR=%~dp0
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%
set ROOT=%SCRIPT_DIR%

set DC=docker compose --project-directory "%ROOT%"
set CORE=-f "%ROOT%\docker\core\docker-compose.yml"
set METRICS=-f "%ROOT%\docker\metrics\docker-compose.yml"

set CMD=%1

if "%CMD%"=="down"   goto :down
if "%CMD%"=="logs"   goto :logs
if "%CMD%"=="status" goto :status
if "%CMD%"=="" goto :up
if /i "%CMD%"=="up" goto :up
goto :usage

:up
echo.
echo [start] 시작 모드를 선택하세요:
echo.
echo   1) 로그만
echo      - Docker: Loki(로그 저장) + Grafana(대시보드)
echo      - 백그라운드: Alloy(라벨링·인덱싱, 호스트에서 직접 실행) + scripts\stream-logs.ps1 (SSH로 원격 로그 수집)
echo.
echo   2) 로그 + 메트릭
echo      - Docker: 1번 + Prometheus(메트릭 저장) + textfile-exporter
echo      - 백그라운드: 1번 + scripts\collect-metrics.ps1 (CPU/메모리 등 수집)
echo.
set /p MODE="선택 [1-2]: "

if "%MODE%"=="1" (
    %DC% %CORE% up -d
    echo.
    echo [start] Grafana: http://localhost:3000
    echo [start] Alloy:   http://localhost:12345
    echo.
    call :start_alloy
    start "LogMonitor-Stream" powershell -NoExit -ExecutionPolicy Bypass -File "%ROOT%\scripts\stream-logs.ps1"
    echo [start] 로그 스트리밍 창이 열렸습니다.
    goto :end
)
if "%MODE%"=="2" (
    %DC% %CORE% %METRICS% up -d
    echo.
    echo [start] Grafana:    http://localhost:3000
    echo [start] Alloy:      http://localhost:12345
    echo [start] Prometheus: http://localhost:9090
    echo.
    call :start_alloy
    start "LogMonitor-Stream"  powershell -NoExit -ExecutionPolicy Bypass -File "%ROOT%\scripts\stream-logs.ps1"
    start "LogMonitor-Metrics" powershell -NoExit -ExecutionPolicy Bypass -File "%ROOT%\scripts\collect-metrics.ps1"
    echo [start] 로그 스트리밍 + 메트릭 수집 창이 열렸습니다.
    goto :end
)
echo [error] 1-2 중 선택하세요
goto :end

:start_alloy
if exist "%ROOT%\scripts\start-alloy.bat" (
    start "LogMonitor-Alloy" cmd /k "%ROOT%\scripts\start-alloy.bat"
    echo [start] Alloy 창이 열렸습니다.
) else (
    echo [start] scripts\start-alloy.bat 없음 -- setup.bat 을 먼저 실행하세요.
)
exit /b 0

:down
taskkill /FI "WINDOWTITLE eq LogMonitor-Stream"  /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq LogMonitor-Metrics" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq LogMonitor-Alloy"   /F >nul 2>&1
echo [start] 백그라운드 프로세스 종료
%DC% %CORE% %METRICS% down
goto :end

:logs
%DC% %CORE% %METRICS% logs -f
goto :end

:status
docker ps --filter "name=loki" --filter "name=grafana" --filter "name=alloy" --filter "name=prometheus" --filter "name=textfile-exporter"
goto :end

:usage
echo 사용법: %~nx0 [up^|down^|logs^|status]
echo.
echo   up      (기본값) 모드를 선택해 서비스를 시작합니다.
echo   down    up으로 시작한 백그라운드 창(로그 스트리밍/메트릭 수집/Alloy)과
echo           Docker 컨테이너를 모두 종료합니다.
echo   logs    현재 구성된 Docker 컨테이너의 로그를 실시간으로 봅니다.
echo   status  loki/grafana/alloy/prometheus/textfile-exporter 컨테이너 상태를 봅니다.
exit /b 1

:end
