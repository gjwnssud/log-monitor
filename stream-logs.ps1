# 로그 로테이션 설정
$MaxSizeMB     = 50   # 로테이션 기준 파일 크기 (MB)
$RotateKeep    = 5    # 보관할 로테이션 파일 개수
$CheckInterval = 30   # 크기 체크 주기 (초)

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir      = Join-Path $ScriptDir "data\logs"
$ServersConf = Join-Path $ScriptDir "servers.conf"

if (-not (Test-Path $ServersConf)) {
    Write-Host "[error] servers.conf 파일이 없습니다."
    exit 1
}

# servers.conf 파싱
$servers = @()
Get-Content $ServersConf | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#')) {
        $parts = $line -split '\s+'
        $servers += @{ alias = $parts[0]; sshHost = $parts[1]; service = $parts[2] }
    }
}

$processes = @()

function Stop-All {
    Write-Host ""
    Write-Host "[stream] 스트리밍 종료 중..."
    foreach ($p in $processes) {
        if (-not $p.HasExited) { $p.Kill() }
    }
    Write-Host "[stream] 종료 완료"
}

function Rotate-Log {
    param($file)
    for ($i = $RotateKeep - 1; $i -ge 1; $i--) {
        $from = "$file.$i"
        $to   = "$file.$($i + 1)"
        if (Test-Path $from) { Move-Item $from $to -Force }
    }
    Copy-Item $file "$file.1" -Force
    Clear-Content $file
    Write-Host "[rotate] $(Split-Path -Leaf $file) rotated"
}

Write-Host "[stream] SSH 로그 스트리밍 시작"
Write-Host ""

foreach ($server in $servers) {
    $logFile = Join-Path $LogDir "$($server.alias).log"
    Write-Host "[stream] $($server.alias) -> $($server.sshHost) ($($server.service))"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "cmd.exe"
    $psi.Arguments = "/c ssh $($server.sshHost) `"journalctl -u $($server.service) -f --output=short-iso`" >> `"$logFile`""
    $psi.UseShellExecute  = $false
    $psi.CreateNoWindow   = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $processes += $p
}

Write-Host ""
Write-Host "[stream] 스트리밍 중... (종료: Ctrl+C)"
Write-Host "[rotate] 로테이션 기준: ${MaxSizeMB}MB, 보관: ${RotateKeep}개, 체크 주기: ${CheckInterval}초"

try {
    while ($true) {
        Start-Sleep $CheckInterval
        foreach ($server in $servers) {
            $logFile = Join-Path $LogDir "$($server.alias).log"
            if (Test-Path $logFile) {
                $sizeMB = (Get-Item $logFile).Length / 1MB
                if ($sizeMB -ge $MaxSizeMB) { Rotate-Log $logFile }
            }
        }
    }
} finally {
    Stop-All
}
