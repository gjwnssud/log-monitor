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

:: servers.conf 확인
if not exist "%SCRIPT_DIR%\servers.conf" (
    echo [error] servers.conf 파일이 없습니다. servers.conf.example을 복사해 수정하세요.
    echo         copy servers.conf.example servers.conf
    exit /b 1
)

:: 디렉토리 생성
if not exist "%SCRIPT_DIR%\data\loki"    mkdir "%SCRIPT_DIR%\data\loki"
if not exist "%SCRIPT_DIR%\data\grafana" mkdir "%SCRIPT_DIR%\data\grafana"
if not exist "%SCRIPT_DIR%\data\alloy"   mkdir "%SCRIPT_DIR%\data\alloy"
if not exist "%SCRIPT_DIR%\data\logs"    mkdir "%SCRIPT_DIR%\data\logs"
echo [setup] data/ 디렉토리 생성 완료

:: alloy-config.alloy 생성 (임시 PowerShell 스크립트 사용)
set PS_TEMP=%TEMP%\generate_alloy_%RANDOM%.ps1
(
    echo $scriptDir = '%SCRIPT_DIR:\=\\%'
    echo $template = Get-Content "$scriptDir\alloy-config.template.alloy"
    echo $servers = Get-Content "$scriptDir\servers.conf" ^| Where-Object { $_ -notmatch '^\s*#' -and $_.Trim^(^) -ne '' }
    echo $entries = @^(^)
    echo foreach ^($line in $servers^) {
    echo     $parts = $line -split '\s+'
    echo     $alias = $parts[0]
    echo     $entries += "    {__path__ = ``""/logs/$alias.log``"", job = ``""logs``"", server = ``""$alias``""},"
    echo }
    echo $out = @^(^)
    echo foreach ^($line in $template^) {
    echo     if ^($line -match '// __SERVERS__'^) { $out += $entries } else { $out += $line }
    echo }
    echo $out ^| Set-Content "$scriptDir\alloy-config.alloy" -Encoding UTF8
) > "%PS_TEMP%"

powershell -ExecutionPolicy Bypass -File "%PS_TEMP%"
del "%PS_TEMP%"

echo [setup] alloy-config.alloy 생성 완료
echo.
echo 다음 단계:
echo   1. docker compose up -d
echo   2. stream-logs.bat
echo   3. 브라우저에서 http://localhost:3000 접속 (Grafana)
echo   4. 브라우저에서 http://localhost:12345 접속 (Alloy UI)
