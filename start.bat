@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

set SCRIPT_DIR=%~dp0
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%
set ROOT=%SCRIPT_DIR%

set DC=docker compose --project-directory "%ROOT%"
set CORE=-f "%ROOT%\docker\core\docker-compose.yml"
set ALLOY=-f "%ROOT%\docker\alloy\docker-compose.yml"
set METRICS=-f "%ROOT%\docker\metrics\docker-compose.yml"

set CMD=%1

if "%CMD%"=="down"   goto :down
if "%CMD%"=="logs"   goto :logs
if "%CMD%"=="status" goto :status

:up
echo.
echo [start] 시작 모드를 선택하세요:
echo   1) 로그만          (Loki + Grafana + 로그 스트리밍)
echo   2) 로그 + 메트릭   (+ Prometheus + 메트릭 수집)
echo   3) 전체            (+ Alloy + 메트릭 수집)
echo.
set /p MODE="선택 [1-3]: "

if "%MODE%"=="1" (
    %DC% %CORE% up -d
    echo.
    echo [start] Grafana: http://localhost:3000
    echo.
    start "LogMonitor-Stream" powershell -NoExit -ExecutionPolicy Bypass -File "%ROOT%\scripts\stream-logs.ps1"
    echo [start] 로그 스트리밍 창이 열렸습니다.
    goto :end
)
if "%MODE%"=="2" (
    %DC% %CORE% %METRICS% up -d
    echo.
    echo [start] Grafana:    http://localhost:3000
    echo [start] Prometheus: http://localhost:9090
    echo.
    start "LogMonitor-Stream"  powershell -NoExit -ExecutionPolicy Bypass -File "%ROOT%\scripts\stream-logs.ps1"
    start "LogMonitor-Metrics" powershell -NoExit -ExecutionPolicy Bypass -File "%ROOT%\scripts\collect-metrics.ps1"
    echo [start] 로그 스트리밍 + 메트릭 수집 창이 열렸습니다.
    goto :end
)
if "%MODE%"=="3" (
    %DC% %CORE% %ALLOY% %METRICS% up -d
    echo.
    echo [start] Grafana:    http://localhost:3000
    echo [start] Alloy:      http://localhost:12345
    echo [start] Prometheus: http://localhost:9090
    echo.
    if exist "%ROOT%\start-alloy.bat" (
        start "LogMonitor-Alloy" cmd /k "%ROOT%\start-alloy.bat"
        echo [start] Alloy 창이 열렸습니다.
    ) else (
        echo [start] start-alloy.bat 없음 -- setup.bat 을 먼저 실행하세요.
    )
    start "LogMonitor-Stream"  powershell -NoExit -ExecutionPolicy Bypass -File "%ROOT%\scripts\stream-logs.ps1"
    start "LogMonitor-Metrics" powershell -NoExit -ExecutionPolicy Bypass -File "%ROOT%\scripts\collect-metrics.ps1"
    echo [start] 로그 스트리밍 + 메트릭 수집 창이 열렸습니다.
    goto :end
)
echo [error] 1-3 중 선택하세요
goto :end

:down
taskkill /FI "WINDOWTITLE eq LogMonitor-Stream"  /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq LogMonitor-Metrics" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq LogMonitor-Alloy"   /F >nul 2>&1
echo [start] 백그라운드 프로세스 종료
%DC% %CORE% %ALLOY% %METRICS% down
goto :end

:logs
%DC% %CORE% %ALLOY% %METRICS% logs -f
goto :end

:status
docker ps --filter "name=loki" --filter "name=grafana" --filter "name=alloy" --filter "name=prometheus" --filter "name=textfile-exporter"
goto :end

:end
