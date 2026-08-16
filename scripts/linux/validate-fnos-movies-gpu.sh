#!/usr/bin/env bash
set -euo pipefail

service=${1:-mediasrv}
transcode_dir=${2:-/vol2/mediasrv.transcode}
command -v nvidia-smi >/dev/null
[[ -c /dev/dxg ]] || { echo '[FAIL] /dev/dxg missing' >&2; exit 1; }
systemctl is-active --quiet "$service"
mapfile -t pids < <(pgrep -x mediasrv || true)
((${#pids[@]})) || { echo '[FAIL] no mediasrv process' >&2; exit 1; }
dxg_open=false
for pid in "${pids[@]}"; do
    for fd in "/proc/$pid"/fd/*; do
        [[ $(readlink "$fd" 2>/dev/null || true) == /dev/dxg ]] && { dxg_open=true; break 2; }
    done
done
$dxg_open || { echo '[FAIL] no current mediasrv process holds /dev/dxg; start a real Movies transcode' >&2; exit 1; }
log=/usr/trim/logs/mediasrv.log
[[ -r $log ]] || { echo "[FAIL] unreadable $log" >&2; exit 1; }
for pattern in 'loaded nvenc api' 'gpu in working' 'gpu enable: true'; do
    grep -F "$pattern" "$log" | tail -n 1 || { echo "[FAIL] missing Movies log marker: $pattern" >&2; exit 1; }
done
before=$(find "$transcode_dir" -type f \( -name '*.ts' -o -name '*.m4s' \) -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1)
echo 'Start or keep a real fnOS Movies quality transcode running now.'
timeout 45 nvidia-smi dmon -s u -d 1 -c 30 | tee /tmp/fnos-movies-gpu-dmon.txt
awk 'NF >= 5 && $1 !~ /^#/ && ($4 + 0 > 0 || $5 + 0 > 0) { found=1 } END { exit !found }' /tmp/fnos-movies-gpu-dmon.txt
sleep 2
after=$(find "$transcode_dir" -type f \( -name '*.ts' -o -name '*.m4s' \) -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1)
[[ -n $after && ${after:-0} != "${before:-0}" ]] || { echo '[FAIL] no new HLS fragment observed' >&2; exit 1; }
if journalctl -k --since '-2 min' --no-pager | grep -Eai 'WARNING:|BUG:|rwsem_assert|dxg_map_iospace|hung task|I/O error|btrfs.*error'; then
    echo '[FAIL] new serious kernel/storage warning' >&2
    exit 1
fi
echo '[PASS] real fnOS Movies activity showed NVENC/NVDEC utilization and new HLS output'
