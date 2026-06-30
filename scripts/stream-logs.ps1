$MaxSizeMB              = 50
$RotateKeep             = 5
$RotationCheckInterval  = 30
$ReconnectCheckInterval = 5
$ReconnectDelay         = 5

$ScriptsDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root        = Split-Path -Parent $ScriptsDir
$LogDir      = Join-Path $Root "data\logs"
$ServersConf = Join-Path $Root "servers.conf"

if (-not (Test-Path $ServersConf)) {
    Write-Host "[error] servers.conf 파일이 없습니다."
    exit 1
}

$servers = @()
Get-Content $ServersConf | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#')) {
        $parts = $line -split '\s+'
        $servers += @{ alias = $parts[0]; sshHost = $parts[1]; service = $parts[2] }
    }
}

function New-SSHProcess {
    param($sshHost, $service, $logFile)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "cmd.exe"
    $psi.Arguments = "/c ssh -o `"ServerAliveInterval=10`" -o `"ServerAliveCountMax=3`" -o `"ConnectTimeout=10`" $sshHost `"journalctl -u $service -f --output=short-iso`" >> `"$logFile`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    return [System.Diagnostics.Process]::Start($psi)
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

function Stop-All {
    Write-Host ""
    Write-Host "[stream] 스트리밍 종료 중..."
    foreach ($s in $script:streamers) {
        if (-not $s.process.HasExited) { $s.process.Kill() }
    }
    Write-Host "[stream] 종료 완료"
}

$streamers = [System.Collections.ArrayList]@()

# 터미널 강제 종료 시에도 자식 프로세스 정리
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Stop-All } | Out-Null

Write-Host "[stream] SSH 로그 스트리밍 시작"
Write-Host ""

foreach ($server in $servers) {
    $logFile = Join-Path $LogDir "$($server.alias).log"
    Write-Host "[stream] $($server.alias) -> $($server.sshHost) ($($server.service))"
    $p = New-SSHProcess $server.sshHost $server.service $logFile
    [void]$streamers.Add([PSCustomObject]@{ server = $server; process = $p; logFile = $logFile })
}

Write-Host ""
Write-Host "[stream] 스트리밍 중... (종료: Ctrl+C)"
Write-Host "[rotate] 로테이션 기준: ${MaxSizeMB}MB, 보관: ${RotateKeep}개, 체크 주기: ${RotationCheckInterval}초"
Write-Host "[reconnect] 재연결 감지 주기: ${ReconnectCheckInterval}초, 재연결 대기: ${ReconnectDelay}초"

$lastRotationCheck = Get-Date

try {
    while ($true) {
        Start-Sleep $ReconnectCheckInterval

        # 재연결 체크
        for ($i = 0; $i -lt $streamers.Count; $i++) {
            $s = $streamers[$i]
            if ($s.process.HasExited) {
                Write-Host "[stream] $($s.server.alias) 연결 끊김. ${ReconnectDelay}초 후 재연결..."
                Start-Sleep $ReconnectDelay
                $newProcess = New-SSHProcess $s.server.sshHost $s.server.service $s.logFile
                $streamers[$i] = [PSCustomObject]@{ server = $s.server; process = $newProcess; logFile = $s.logFile }
                Write-Host "[stream] $($s.server.alias) 재연결 완료"
            }
        }

        # 로테이션 체크
        $now = Get-Date
        if (($now - $lastRotationCheck).TotalSeconds -ge $RotationCheckInterval) {
            $lastRotationCheck = $now
            foreach ($s in $streamers) {
                if (Test-Path $s.logFile) {
                    $sizeMB = (Get-Item $s.logFile).Length / 1MB
                    if ($sizeMB -ge $MaxSizeMB) { Rotate-Log $s.logFile }
                }
            }
        }
    }
} finally {
    Stop-All
}
