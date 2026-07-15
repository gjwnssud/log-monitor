$Interval              = 10    # 수집 주기(초) — prometheus.yml scrape_interval 과 맞출 것
$ReconnectDelay        = 5
$MaxSizeMB             = 10
$RotateKeep            = 5
$RotationCheckInterval = 60

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
import sys, re, time, json, os

alias      = sys.argv[1]
group      = sys.argv[2]
cache_file = sys.argv[3] if len(sys.argv) > 3 else None
data       = sys.stdin.read()

parts    = data.split('___SEP___')
proc_raw = parts[0] if len(parts) > 0 else ''
df_raw   = parts[1] if len(parts) > 1 else ''

metrics = {}

def add(name, help_text, mtype, sample):
    if name not in metrics:
        metrics[name] = (help_text, mtype, [])
    metrics[name][2].append(sample)

# ── CPU 사용률 (/proc/stat) ───────────────────────────────────────────────────
for line in proc_raw.splitlines():
    m = re.match(r'^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)', line)
    if m:
        user, nice, system, idle, iowait, irq, softirq = [int(x) for x in m.groups()]
        total      = user + nice + system + idle + iowait + irq + softirq
        idle_total = idle + iowait
        curr = {'total': total, 'idle': idle_total}

        if cache_file:
            prev = None
            if os.path.exists(cache_file):
                try:
                    with open(cache_file) as f:
                        prev = json.load(f)
                except Exception:
                    pass
            try:
                with open(cache_file, 'w') as f:
                    json.dump(curr, f)
            except Exception:
                pass

            if prev:
                d_total = curr['total'] - prev['total']
                d_idle  = curr['idle']  - prev['idle']
                if d_total > 0:
                    usage = round((d_total - d_idle) / d_total * 100, 2)
                    add('server_cpu_usage_percent', 'CPU 사용률 (%)', 'gauge',
                        f'server_cpu_usage_percent{{server="{alias}",group="{group}"}} {usage}')
        break

# ── Memory ────────────────────────────────────────────────────────────────────
mem = {}
for line in proc_raw.splitlines():
    m = re.match(r'^(\w+):\s+(\d+)\s+kB', line)
    if m:
        mem[m.group(1)] = int(m.group(2)) * 1024

if 'MemTotal' in mem and 'MemAvailable' in mem:
    add('server_memory_total_bytes',     '전체 메모리 (bytes)',      'gauge', f'server_memory_total_bytes{{server="{alias}",group="{group}"}} {mem["MemTotal"]}')
    add('server_memory_available_bytes', '사용 가능 메모리 (bytes)', 'gauge', f'server_memory_available_bytes{{server="{alias}",group="{group}"}} {mem["MemAvailable"]}')

# ── Network ───────────────────────────────────────────────────────────────────
SKIP_IFACE = ('lo', 'veth', 'br-', 'docker', 'flannel', 'cali', 'cilium')
in_net = net_header = False

for line in proc_raw.splitlines():
    if 'Inter-' in line:
        in_net = True; continue
    if in_net and not net_header and 'bytes' in line:
        net_header = True; continue
    if in_net and net_header and ':' in line:
        iface_part, stat_part = line.split(':', 1)
        iface = iface_part.strip()
        if any(iface.startswith(p) for p in SKIP_IFACE):
            continue
        nums = stat_part.split()
        if len(nums) >= 9:
            add('server_network_receive_bytes_total',  '네트워크 수신 누적 (bytes)', 'counter',
                f'server_network_receive_bytes_total{{server="{alias}",group="{group}",interface="{iface}"}} {nums[0]}')
            add('server_network_transmit_bytes_total', '네트워크 송신 누적 (bytes)', 'counter',
                f'server_network_transmit_bytes_total{{server="{alias}",group="{group}",interface="{iface}"}} {nums[8]}')

# ── Disk ──────────────────────────────────────────────────────────────────────
SKIP_FS = {'tmpfs', 'devtmpfs', 'squashfs', 'udev', 'overlay', 'shm', 'cgroup', 'cgroup2'}
df_header = False

for line in df_raw.splitlines():
    line = line.strip()
    if not line: continue
    if not df_header:
        df_header = True; continue
    cols = line.split()
    if len(cols) < 6: continue
    fs, mount = cols[0], cols[5]
    if fs in SKIP_FS or any(fs.startswith(p) for p in ('tmpfs', 'devtmpfs', 'squashfs', 'overlay')):
        continue
    try:
        total = int(cols[1]) * 1024
        used  = int(cols[2]) * 1024
        add('server_disk_total_bytes', '디스크 전체 크기 (bytes)', 'gauge',
            f'server_disk_total_bytes{{server="{alias}",group="{group}",mountpoint="{mount}"}} {total}')
        add('server_disk_used_bytes',  '디스크 사용량 (bytes)',    'gauge',
            f'server_disk_used_bytes{{server="{alias}",group="{group}",mountpoint="{mount}"}} {used}')
    except Exception:
        pass

# ── 수집 시각 ─────────────────────────────────────────────────────────────────
add('server_metrics_collected_timestamp', '마지막 수집 시각 (Unix timestamp)', 'gauge',
    f'server_metrics_collected_timestamp{{server="{alias}",group="{group}"}} {int(time.time())}')

# ── 출력 (HELP/TYPE 메트릭명당 1회) ──────────────────────────────────────────
out = []
for name, (help_text, mtype, samples) in metrics.items():
    out.append(f'# HELP {name} {help_text}')
    out.append(f'# TYPE {name} {mtype}')
    out.extend(samples)

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
        $group = if ($parts.Length -ge 4) { $parts[3] } else { 'default' }
        $servers += @{ alias = $parts[0]; sshHost = $parts[1]; group = $group }
    }
}

function Rotate-Prom {
    param($file)
    if (-not (Test-Path $file)) { return }
    for ($i = $RotateKeep - 1; $i -ge 1; $i--) {
        $from = "$file.$i"
        $to   = "$file.$($i + 1)"
        if (Test-Path $from) { Move-Item $from $to -Force }
    }
    Copy-Item $file "$file.1" -Force
    Write-Host "[rotate] $(Split-Path -Leaf $file) rotated (보관: ${RotateKeep}개)"
}

$Jobs = [System.Collections.ArrayList]@()

function Stop-All {
    Write-Host ""
    Write-Host "[metrics] 수집 종료 중..."
    foreach ($job in $script:Jobs) {
        Stop-Job   $job -ErrorAction SilentlyContinue
        Remove-Job $job -ErrorAction SilentlyContinue
    }
    Write-Host "[metrics] 종료 완료"
}

Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Stop-All } | Out-Null

Write-Host "[metrics] SSH 메트릭 수집 시작"
Write-Host ""

foreach ($server in $servers) {
    $alias     = $server.alias
    $sshHost   = $server.sshHost
    $group     = $server.group
    $outFile   = Join-Path $MetricsDir "$group-$alias.prom"
    $cacheFile = Join-Path $MetricsDir ".cpu_$group-$alias.cache"

    Write-Host "[metrics] $alias ($sshHost) [$group]: 수집 시작"

    $job = Start-Job -ScriptBlock {
        param($sshHost, $alias, $group, $outFile, $cacheFile, $parserScript, $pythonCmd, $interval, $reconnectDelay)

        $sshCmd = "cat /proc/stat /proc/meminfo /proc/net/dev && printf '\n___SEP___\n' && df -P 2>/dev/null"

        while ($true) {
            $raw = & ssh `
                -o "ConnectTimeout=10" `
                -o "BatchMode=yes" `
                -o "StrictHostKeyChecking=no" `
                -o "ServerAliveInterval=10" `
                -o "ServerAliveCountMax=3" `
                $sshHost $sshCmd 2>$null

            if ($LASTEXITCODE -eq 0 -and $raw) {
                $tmpFile = "$outFile.tmp"
                $result  = $raw | & $pythonCmd $parserScript $alias $group $cacheFile 2>$null
                if ($result) {
                    $result | Set-Content $tmpFile -Encoding UTF8 -NoNewline
                    if (Test-Path $outFile) { Remove-Item $outFile -Force }
                    Move-Item $tmpFile $outFile -Force
                }
            } else {
                Write-Host "[metrics] ${alias}: 수집 실패, 이전 데이터 유지. ${reconnectDelay}초 후 재시도..."
                Start-Sleep $reconnectDelay
                continue
            }

            Start-Sleep $interval
        }
    } -ArgumentList $sshHost, $alias, $group, $outFile, $cacheFile, $ParserScript, $PythonCmd, $Interval, $ReconnectDelay

    [void]$Jobs.Add($job)
}

Write-Host ""
Write-Host "[metrics] 전체 서버 수집 중... (종료: Ctrl+C)"
Write-Host "[rotate]  로테이션 기준: ${MaxSizeMB}MB, 보관: ${RotateKeep}개, 체크 주기: ${RotationCheckInterval}초"
Write-Host "[reconnect] 재연결 대기: ${ReconnectDelay}초 (SSH keepalive: 10s × 3회)"

$lastRotationCheck = Get-Date

try {
    while ($true) {
        Start-Sleep 2

        foreach ($job in $Jobs) {
            Receive-Job $job -ErrorAction SilentlyContinue
        }

        # 로테이션 체크
        $now = Get-Date
        if (($now - $lastRotationCheck).TotalSeconds -ge $RotationCheckInterval) {
            $lastRotationCheck = $now
            foreach ($server in $servers) {
                $promFile = Join-Path $MetricsDir "$($server.group)-$($server.alias).prom"
                if (Test-Path $promFile) {
                    $sizeMB = (Get-Item $promFile).Length / 1MB
                    if ($sizeMB -ge $MaxSizeMB) { Rotate-Prom $promFile }
                }
            }
        }
    }
} finally {
    Stop-All
}
