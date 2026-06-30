$Interval       = 30
$ReconnectDelay = 5

$ScriptsDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root        = Split-Path -Parent $ScriptsDir
$MetricsDir  = Join-Path $Root "data\metrics"
$ServersConf = Join-Path $Root "servers.conf"

if (-not (Test-Path $MetricsDir)) { New-Item -ItemType Directory -Path $MetricsDir -Force | Out-Null }

# Python 3 확인
$PythonCmd = $null
foreach ($cmd in @('python3', 'python')) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        $ver = & $cmd -c "import sys; print(sys.version_info.major)" 2>$null
        if ($ver -eq '3') { $PythonCmd = $cmd; break }
    }
}
if (-not $PythonCmd) {
    Write-Host "[error] Python 3가 설치되어 있지 않습니다. https://www.python.org 에서 설치하세요."
    exit 1
}

# Python 파서를 data/metrics/ 에 1회 생성
$ParserScript = Join-Path $MetricsDir ".parser.py"
@'
#!/usr/bin/env python3
import sys, re, time

alias = sys.argv[1]
data  = sys.stdin.read()

parts    = data.split('___SEP___')
proc_raw = parts[0] if len(parts) > 0 else ''
df_raw   = parts[1] if len(parts) > 1 else ''

out = []

# Load average
for line in proc_raw.splitlines():
    m = re.match(r'^([\d.]+)\s+([\d.]+)\s+([\d.]+)', line)
    if m:
        out += [
            f'# HELP server_load_avg_1m  1분 부하 평균',
            f'# TYPE server_load_avg_1m gauge',
            f'server_load_avg_1m{{server="{alias}"}} {m.group(1)}',
            f'# HELP server_load_avg_5m  5분 부하 평균',
            f'# TYPE server_load_avg_5m gauge',
            f'server_load_avg_5m{{server="{alias}"}} {m.group(2)}',
            f'# HELP server_load_avg_15m 15분 부하 평균',
            f'# TYPE server_load_avg_15m gauge',
            f'server_load_avg_15m{{server="{alias}"}} {m.group(3)}',
        ]
        break

# Memory
mem = {}
for line in proc_raw.splitlines():
    m = re.match(r'^(\w+):\s+(\d+)\s+kB', line)
    if m:
        mem[m.group(1)] = int(m.group(2)) * 1024

if 'MemTotal' in mem and 'MemAvailable' in mem:
    out += [
        f'# HELP server_memory_total_bytes     전체 메모리 (bytes)',
        f'# TYPE server_memory_total_bytes gauge',
        f'server_memory_total_bytes{{server="{alias}"}} {mem["MemTotal"]}',
        f'# HELP server_memory_available_bytes 사용 가능 메모리 (bytes)',
        f'# TYPE server_memory_available_bytes gauge',
        f'server_memory_available_bytes{{server="{alias}"}} {mem["MemAvailable"]}',
    ]

# Network
SKIP_IFACE_PREFIX = ('lo', 'veth', 'br-', 'docker', 'flannel', 'cali', 'cilium')
in_net = False
net_header_seen = False

for line in proc_raw.splitlines():
    if 'Inter-' in line:
        in_net = True
        continue
    if in_net and not net_header_seen and 'bytes' in line:
        net_header_seen = True
        continue
    if in_net and net_header_seen and ':' in line:
        iface_part, stat_part = line.split(':', 1)
        iface = iface_part.strip()
        if any(iface.startswith(p) for p in SKIP_IFACE_PREFIX):
            continue
        nums = stat_part.split()
        if len(nums) >= 9:
            out += [
                f'# HELP server_network_receive_bytes_total  네트워크 수신 누적 (bytes)',
                f'# TYPE server_network_receive_bytes_total counter',
                f'server_network_receive_bytes_total{{server="{alias}",interface="{iface}"}} {nums[0]}',
                f'# HELP server_network_transmit_bytes_total 네트워크 송신 누적 (bytes)',
                f'# TYPE server_network_transmit_bytes_total counter',
                f'server_network_transmit_bytes_total{{server="{alias}",interface="{iface}"}} {nums[8]}',
            ]

# Disk
SKIP_FS = {'tmpfs', 'devtmpfs', 'squashfs', 'udev', 'overlay', 'shm', 'cgroup', 'cgroup2'}
df_header_seen = False
for line in df_raw.splitlines():
    line = line.strip()
    if not line:
        continue
    if not df_header_seen:
        df_header_seen = True
        continue
    cols = line.split()
    if len(cols) < 6:
        continue
    fs, mount = cols[0], cols[5]
    if fs in SKIP_FS or any(fs.startswith(p) for p in ('tmpfs', 'devtmpfs', 'squashfs', 'overlay')):
        continue
    try:
        total = int(cols[1]) * 1024
        used  = int(cols[2]) * 1024
        out += [
            f'# HELP server_disk_total_bytes 디스크 전체 크기 (bytes)',
            f'# TYPE server_disk_total_bytes gauge',
            f'server_disk_total_bytes{{server="{alias}",mountpoint="{mount}"}} {total}',
            f'# HELP server_disk_used_bytes  디스크 사용량 (bytes)',
            f'# TYPE server_disk_used_bytes gauge',
            f'server_disk_used_bytes{{server="{alias}",mountpoint="{mount}"}} {used}',
        ]
    except ValueError:
        pass

out += [
    f'# HELP server_metrics_collected_timestamp 마지막 수집 시각 (Unix timestamp)',
    f'# TYPE server_metrics_collected_timestamp gauge',
    f'server_metrics_collected_timestamp{{server="{alias}"}} {int(time.time())}',
]

print('\n'.join(out))
'@ | Set-Content $ParserScript -Encoding UTF8

if (-not (Test-Path $ServersConf)) {
    Write-Host "[error] servers.conf 파일이 없습니다."
    exit 1
}

$servers = @()
Get-Content $ServersConf | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#')) {
        $parts = $line -split '\s+'
        $servers += @{ alias = $parts[0]; sshHost = $parts[1] }
    }
}

$Jobs = [System.Collections.ArrayList]@()

function Stop-All {
    Write-Host ""
    Write-Host "[metrics] 수집 종료 중..."
    foreach ($job in $script:Jobs) {
        Stop-Job  $job -ErrorAction SilentlyContinue
        Remove-Job $job -ErrorAction SilentlyContinue
    }
    Write-Host "[metrics] 종료 완료"
}

Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Stop-All } | Out-Null

Write-Host "[metrics] SSH 메트릭 수집 시작"
Write-Host ""

foreach ($server in $servers) {
    $alias   = $server.alias
    $sshHost = $server.sshHost
    $outFile = Join-Path $MetricsDir "$alias.prom"

    Write-Host "[metrics] $alias ($sshHost): 수집 시작"

    $job = Start-Job -ScriptBlock {
        param($sshHost, $alias, $outFile, $parserScript, $pythonCmd, $interval, $reconnectDelay)

        $sshCmd = "cat /proc/loadavg /proc/meminfo /proc/net/dev && echo ___SEP___ && df -P 2>/dev/null"

        while ($true) {
            $raw = & ssh `
                -o "ConnectTimeout=5" `
                -o "BatchMode=yes" `
                -o "StrictHostKeyChecking=no" `
                $sshHost $sshCmd 2>$null

            if ($LASTEXITCODE -eq 0 -and $raw) {
                $result = $raw | & $pythonCmd $parserScript $alias
                $result | Set-Content $outFile -Encoding UTF8 -NoNewline
            } else {
                Write-Host "[metrics] $alias`: SSH 연결 실패, ${reconnectDelay}초 후 재시도..."
                Set-Content $outFile "" -Encoding UTF8
                Start-Sleep $reconnectDelay
                continue
            }

            Start-Sleep $interval
        }
    } -ArgumentList $sshHost, $alias, $outFile, $ParserScript, $PythonCmd, $Interval, $ReconnectDelay

    [void]$Jobs.Add($job)
}

Write-Host ""
Write-Host "[metrics] 전체 서버 수집 중... (종료: Ctrl+C)"
Write-Host "[metrics] 수집 주기: ${Interval}초, 재연결 대기: ${ReconnectDelay}초"

try {
    while ($true) {
        foreach ($job in $Jobs) {
            Receive-Job $job -ErrorAction SilentlyContinue
        }
        Start-Sleep 5
    }
} finally {
    Stop-All
}
