@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

set SCRIPT_DIR=%~dp0
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%

:: .env 확인
if not exist "%SCRIPT_DIR%\.env" (
    copy "%SCRIPT_DIR%\.env.example" "%SCRIPT_DIR%\.env" >nul
    echo [setup] .env 파일 생성 완료 (.env.example 복사)
)

:: 디렉토리 생성
if not exist "%SCRIPT_DIR%\data\loki"    mkdir "%SCRIPT_DIR%\data\loki"
if not exist "%SCRIPT_DIR%\data\grafana" mkdir "%SCRIPT_DIR%\data\grafana"
if not exist "%SCRIPT_DIR%\data\alloy"   mkdir "%SCRIPT_DIR%\data\alloy"
if not exist "%SCRIPT_DIR%\data\logs"    mkdir "%SCRIPT_DIR%\data\logs"
echo [setup] data/ 디렉토리 생성 완료

:: Alloy 수집 방식 선택
echo.
echo [setup] Alloy 수집 방식을 선택하세요:
echo   1) SSH 스트리밍       (서버 설치 권한 없음, stream-logs.bat 사용)
echo   2) Journal 직접 읽기  (서버에 Alloy 설치, systemd 서비스 로그)
echo   3) 파일 직접 읽기     (서버에 Alloy 설치, 파일 경로 지정)
echo.
set /p CHOICE="선택 [1-3]: "

if "%CHOICE%"=="1" goto :ssh_stream
if "%CHOICE%"=="2" goto :journal
if "%CHOICE%"=="3" goto :file
echo [error] 올바른 번호를 입력하세요 (1-3)
exit /b 1

:ssh_stream
:: servers.conf 확인
if not exist "%SCRIPT_DIR%\servers.conf" (
    echo [error] servers.conf 파일이 없습니다. servers.conf.example을 복사해 수정하세요.
    echo         copy servers.conf.example servers.conf
    exit /b 1
)

:: alloy-config.alloy 생성 (Windows 호스트 경로 사용)
set PS_TEMP=%TEMP%\generate_alloy_%RANDOM%.ps1
set LOG_DIR=%SCRIPT_DIR%\data\logs
set LOG_DIR_FWD=%LOG_DIR:\=/%

(
    echo $scriptDir = '%SCRIPT_DIR:\=\\%'
    echo $template = Get-Content "$scriptDir\alloy-config.host.template.alloy"
    echo $servers = Get-Content "$scriptDir\servers.conf" ^| Where-Object { $_ -notmatch '^\s*#' -and $_.Trim^(^) -ne '' }
    echo $logDir = '%LOG_DIR_FWD%'
    echo $entries = @^(^)
    echo foreach ^($line in $servers^) {
    echo     $parts = $line -split '\s+'
    echo     $alias = $parts[0]
    echo     $entries += "    {__path__ = ``""$logDir/$alias.log``"", job = ``""logs``"", server = ``""$alias``""},"
    echo }
    echo $out = @^(^)
    echo foreach ^($line in $template^) {
    echo     if ^($line -match '// __SERVERS__'^) { $out += $entries } else { $out += $line }
    echo }
    echo $out ^| Set-Content "$scriptDir\alloy-config.alloy" -Encoding UTF8
) > "%PS_TEMP%"

powershell -ExecutionPolicy Bypass -File "%PS_TEMP%"
del "%PS_TEMP%"

echo [setup] alloy-config.alloy 생성 완료 (SSH 스트리밍)

:: start-alloy.bat 생성
(
    echo @echo off
    echo set SCRIPT_DIR=%%~dp0
    echo set SCRIPT_DIR=%%SCRIPT_DIR:~0,-1%%
    echo alloy run --storage.path "%%SCRIPT_DIR%%\data\alloy" "%%SCRIPT_DIR%%\alloy-config.alloy"
) > "%SCRIPT_DIR%\start-alloy.bat"

echo [setup] start-alloy.bat 생성 완료
echo.
echo [Windows] Alloy를 호스트에서 직접 실행합니다 (Docker 파일 감시 한계 우회)
echo.
echo 다음 단계:
echo   1. Alloy 설치 (최초 1회):
echo      winget install Grafana.Alloy
echo.
echo   2. Docker 서비스 시작 (Loki + Grafana):
echo      docker compose up -d
echo.
echo   3. Alloy 실행 (새 터미널에서):
echo      start-alloy.bat
echo.
echo   4. 로그 스트리밍 시작 (또 다른 터미널에서):
echo      stream-logs.bat
echo.
echo   5. 브라우저 접속:
echo      Grafana: http://localhost:3000
echo      Alloy:   http://localhost:12345
goto :end

:journal
copy "%SCRIPT_DIR%\alloy-config-journal.template.alloy" "%SCRIPT_DIR%\alloy-config.alloy" >nul
echo [setup] alloy-config.alloy 생성 완료 (Journal 직접 읽기)
echo.
echo 다음 단계:
echo   1. alloy-config.alloy 에서 SERVER_ALIAS, LOKI_HOST 수정
echo   2. 각 서버에 Alloy 설치 후 config 배포
goto :end

:file
copy "%SCRIPT_DIR%\alloy-config-file.template.alloy" "%SCRIPT_DIR%\alloy-config.alloy" >nul
echo [setup] alloy-config.alloy 생성 완료 (파일 직접 읽기)
echo.
echo 다음 단계:
echo   1. alloy-config.alloy 에서 SERVER_ALIAS, LOKI_HOST, 로그 경로 수정
echo   2. 각 서버에 Alloy 설치 후 config 배포

:end
