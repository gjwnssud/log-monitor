@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

set SCRIPT_DIR=%~dp0
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%
set ROOT=%SCRIPT_DIR%

set DC=docker compose --project-directory "%ROOT%"
set CORE=-f "%ROOT%\modules\core\docker-compose.yml"
set ALLOY=-f "%ROOT%\modules\alloy\docker-compose.yml"
set METRICS=-f "%ROOT%\modules\metrics\docker-compose.yml"

set CMD=%1

if "%CMD%"=="down"   goto :down
if "%CMD%"=="logs"   goto :logs
if "%CMD%"=="status" goto :status

:up
echo.
echo [start] 시작 모드를 선택하세요:
echo   1) 로그만          (Loki + Grafana)
echo   2) 로그 + 메트릭   (+ Prometheus)
echo   3) 전체            (+ Alloy Docker, Linux 전용)
echo.
set /p MODE="선택 [1-3]: "

if "%MODE%"=="1" (
    set "ROOT=%ROOT%"
    %DC% %CORE% up -d
    echo.
    echo [start] 서비스 시작 완료
    echo   Grafana:  http://localhost:3000
    echo.
    echo [start] 로그 스트리밍:
    echo   scripts\stream-logs.bat
    goto :end
)
if "%MODE%"=="2" (
    set "ROOT=%ROOT%"
    %DC% %CORE% %METRICS% up -d
    echo.
    echo [start] 서비스 시작 완료
    echo   Grafana:     http://localhost:3000
    echo   Prometheus:  http://localhost:9090
    echo.
    echo [start] 다음 단계 ^(새 터미널^):
    echo   로그 스트리밍: scripts\stream-logs.bat
    echo   메트릭 수집:   powershell -ExecutionPolicy Bypass -File scripts\collect-metrics.ps1
    goto :end
)
if "%MODE%"=="3" (
    set "ROOT=%ROOT%"
    %DC% %CORE% %ALLOY% %METRICS% up -d
    echo.
    echo [start] 서비스 시작 완료
    echo   Grafana:     http://localhost:3000
    echo   Alloy:       http://localhost:12345
    echo   Prometheus:  http://localhost:9090
    echo.
    echo [start] 다음 단계 ^(새 터미널^):
    echo   로그 스트리밍: scripts\stream-logs.bat
    echo   메트릭 수집:   powershell -ExecutionPolicy Bypass -File scripts\collect-metrics.ps1
    goto :end
)
echo [error] 1-3 중 선택하세요
goto :end

:down
set "ROOT=%ROOT%"
%DC% %CORE% %ALLOY% %METRICS% down
goto :end

:logs
set "ROOT=%ROOT%"
%DC% %CORE% %ALLOY% %METRICS% logs -f
goto :end

:status
docker ps --filter "name=loki" --filter "name=grafana" --filter "name=alloy" --filter "name=prometheus" --filter "name=textfile-exporter"
goto :end

:end
