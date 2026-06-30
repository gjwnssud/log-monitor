#!/usr/bin/env bash
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
METRICS_DIR="$ROOT/data/metrics"
INTERVAL=30
RECONNECT_DELAY=5
PIDS=()

mkdir -p "$METRICS_DIR"

# Python 파서를 data/ 디렉토리에 1회 생성 (gitignore 대상)
PARSER="$METRICS_DIR/.parser.py"
cat > "$PARSER" << 'PYEOF'
#!/usr/bin/env python3
import sys, re, time

alias = sys.argv[1]
data  = sys.stdin.read()

# ───SEP─── 구분자로 /proc 섹션과 df 섹션 분리
parts    = data.split('___SEP___')
proc_raw = parts[0] if len(parts) > 0 else ''
df_raw   = parts[1] if len(parts) > 1 else ''

out = []

# ── Load average (/proc/loadavg 첫 줄) ───────────────────────────────────────
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

# ── Memory (/proc/meminfo) ────────────────────────────────────────────────────
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

# ── Network (/proc/net/dev) ───────────────────────────────────────────────────
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

# ── Disk (df -P) ──────────────────────────────────────────────────────────────
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

# ── 수집 시각 ─────────────────────────────────────────────────────────────────
out += [
    f'# HELP server_metrics_collected_timestamp 마지막 수집 시각 (Unix timestamp)',
    f'# TYPE server_metrics_collected_timestamp gauge',
    f'server_metrics_collected_timestamp{{server="{alias}"}} {int(time.time())}',
]

print('\n'.join(out))
PYEOF

cleanup() {
    echo ""
    echo "[metrics] 수집 종료 중..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    echo "[metrics] 종료 완료"
}
trap cleanup EXIT INT TERM HUP

collect_server() {
    local alias="$1"
    local ssh_host="$2"
    local out_file="$METRICS_DIR/${alias}.prom"

    echo "[metrics] $alias ($ssh_host): 수집 시작"

    while true; do
        raw=$(ssh \
            -o ConnectTimeout=5 \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            "$ssh_host" \
            "cat /proc/loadavg /proc/meminfo /proc/net/dev && printf '\n___SEP___\n' && df -P 2>/dev/null" \
            2>/dev/null) \
            && echo "$raw" | python3 "$PARSER" "$alias" > "$out_file" \
            || {
                echo "[metrics] $alias: SSH 연결 실패, ${RECONNECT_DELAY}초 후 재시도..."
                > "$out_file"
                sleep "$RECONNECT_DELAY"
                continue
            }

        sleep "$INTERVAL"
    done
}

if [ ! -f "$ROOT/servers.conf" ]; then
    echo "[error] servers.conf 파일이 없습니다."
    exit 1
fi

while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    read -r alias ssh_host _rest <<< "$line"
    collect_server "$alias" "$ssh_host" &
    PIDS+=($!)
done < "$ROOT/servers.conf"

echo "[metrics] 전체 서버 수집 시작. Ctrl+C로 종료."
wait
