#!/usr/bin/env bash
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
METRICS_DIR="$ROOT/data/metrics"
INTERVAL=10        # 수집 주기(초) — prometheus.yml scrape_interval 과 맞출 것
RECONNECT_DELAY=5
MAX_SIZE_MB=10     # .prom 로테이션 임계치
ROTATE_KEEP=5      # 보관할 .prom 백업 수
CHECK_INTERVAL=60  # 로테이션 체크 주기(초)
PIDS=()

mkdir -p "$METRICS_DIR"

# Python 파서를 data/ 디렉토리에 1회 생성 (gitignore 대상)
PARSER="$METRICS_DIR/.parser.py"
cat > "$PARSER" << 'PYEOF'
#!/usr/bin/env python3
import sys, re, time, json, os

alias      = sys.argv[1]
cache_file = sys.argv[2] if len(sys.argv) > 2 else None
data       = sys.stdin.read()

parts    = data.split('___SEP___')
proc_raw = parts[0] if len(parts) > 0 else ''
df_raw   = parts[1] if len(parts) > 1 else ''

# Prometheus text format: HELP/TYPE 한 번, 샘플은 모아서 출력
metrics = {}  # name -> (help, type, [sample_lines])

def add(name, help_text, mtype, sample):
    if name not in metrics:
        metrics[name] = (help_text, mtype, [])
    metrics[name][2].append(sample)

# ── CPU 사용률 (/proc/stat) ───────────────────────────────────────────────────
# cpu  user nice system idle iowait irq softirq steal ...
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
                        f'server_cpu_usage_percent{{server="{alias}"}} {usage}')
        break

# ── Memory ────────────────────────────────────────────────────────────────────
mem = {}
for line in proc_raw.splitlines():
    m = re.match(r'^(\w+):\s+(\d+)\s+kB', line)
    if m:
        mem[m.group(1)] = int(m.group(2)) * 1024

if 'MemTotal' in mem and 'MemAvailable' in mem:
    add('server_memory_total_bytes',     '전체 메모리 (bytes)',      'gauge', f'server_memory_total_bytes{{server="{alias}"}} {mem["MemTotal"]}')
    add('server_memory_available_bytes', '사용 가능 메모리 (bytes)', 'gauge', f'server_memory_available_bytes{{server="{alias}"}} {mem["MemAvailable"]}')

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
                f'server_network_receive_bytes_total{{server="{alias}",interface="{iface}"}} {nums[0]}')
            add('server_network_transmit_bytes_total', '네트워크 송신 누적 (bytes)', 'counter',
                f'server_network_transmit_bytes_total{{server="{alias}",interface="{iface}"}} {nums[8]}')

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
            f'server_disk_total_bytes{{server="{alias}",mountpoint="{mount}"}} {total}')
        add('server_disk_used_bytes',  '디스크 사용량 (bytes)',    'gauge',
            f'server_disk_used_bytes{{server="{alias}",mountpoint="{mount}"}} {used}')
    except ValueError:
        pass

# ── 수집 시각 ─────────────────────────────────────────────────────────────────
add('server_metrics_collected_timestamp', '마지막 수집 시각 (Unix timestamp)', 'gauge',
    f'server_metrics_collected_timestamp{{server="{alias}"}} {int(time.time())}')

# ── 출력 (HELP/TYPE 메트릭명당 1회) ──────────────────────────────────────────
out = []
for name, (help_text, mtype, samples) in metrics.items():
    out.append(f'# HELP {name} {help_text}')
    out.append(f'# TYPE {name} {mtype}')
    out.extend(samples)

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

file_size_mb() {
    local file="$1"
    local size
    size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
    echo $(( size / 1024 / 1024 ))
}

rotate_prom() {
    local file="$1"
    [ -f "$file" ] || return 0
    for i in $(seq $((ROTATE_KEEP - 1)) -1 1); do
        [ -f "${file}.${i}" ] && mv "${file}.${i}" "${file}.$((i + 1))"
    done
    cp "$file" "${file}.1"
    echo "[rotate] $(basename "$file") rotated (보관: ${ROTATE_KEEP}개)"
}

monitor_rotation() {
    while true; do
        sleep "$CHECK_INTERVAL"
        while IFS= read -r line || [ -n "$line" ]; do
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            read -r alias _ _ <<< "$line"
            local prom_file="$METRICS_DIR/${alias}.prom"
            if [ -f "$prom_file" ] && [ "$(file_size_mb "$prom_file")" -ge "$MAX_SIZE_MB" ]; then
                rotate_prom "$prom_file"
            fi
        done < "$ROOT/servers.conf"
    done
}

collect_server() {
    local alias="$1"
    local ssh_host="$2"
    local out_file="$METRICS_DIR/${alias}.prom"
    local cache_file="$METRICS_DIR/.cpu_${alias}.cache"
    local tmp_file="${out_file}.tmp"

    trap 'exit 0' TERM INT

    echo "[metrics] $alias ($ssh_host): 수집 시작"

    while true; do
        raw=$(ssh \
            -o ConnectTimeout=10 \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            -o ServerAliveInterval=10 \
            -o ServerAliveCountMax=3 \
            "$ssh_host" \
            "cat /proc/stat /proc/meminfo /proc/net/dev && printf '\n___SEP___\n' && df -P 2>/dev/null" \
            2>/dev/null)

        if [ -n "$raw" ] && echo "$raw" | python3 "$PARSER" "$alias" "$cache_file" > "$tmp_file" 2>/dev/null; then
            mv "$tmp_file" "$out_file"
        else
            rm -f "$tmp_file"
            echo "[metrics] $alias: 수집 실패, 이전 데이터 유지. ${RECONNECT_DELAY}초 후 재시도..."
            sleep "$RECONNECT_DELAY"
            continue
        fi

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

monitor_rotation &
PIDS+=($!)

echo "[metrics] 전체 서버 수집 시작. Ctrl+C로 종료."
echo "[rotate] 로테이션 기준: ${MAX_SIZE_MB}MB, 보관: ${ROTATE_KEEP}개, 체크 주기: ${CHECK_INTERVAL}초"
echo "[reconnect] 재연결 대기: ${RECONNECT_DELAY}초 (SSH keepalive: 10s × 3회)"
wait
