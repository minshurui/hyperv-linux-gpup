#!/usr/bin/env bash
set -euo pipefail
usage() { echo "Usage: $0 /path/to/dxgkrnl.ko [--kernel-build DIR]"; }
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
ko=$1; shift
kdir="/usr/src/linux-headers-$(uname -r)"
if [[ ${1:-} == --kernel-build ]]; then kdir=${2:?}; shift 2; fi
[[ $# -eq 0 ]] || { usage >&2; exit 2; }
[[ -r $ko ]] || { echo "Module not readable: $ko" >&2; exit 1; }
[[ -r $kdir/Module.symvers ]] || { echo "Module.symvers not readable: $kdir" >&2; exit 1; }
release=$(uname -r)
vermagic=$(modinfo -F vermagic "$ko")
[[ $vermagic == "$release "* ]] || { echo "[FAIL] vermagic: $vermagic (running $release)"; exit 1; }
echo "[PASS] vermagic matches $release"
for cfg in CONFIG_64BIT CONFIG_HYPERV CONFIG_PCI CONFIG_DMA_SHARED_BUFFER CONFIG_SYNC_FILE CONFIG_MODULES; do
    if grep -q "^$cfg=[ym]" "/boot/config-$release" 2>/dev/null; then echo "[PASS] $cfg"; else echo "[FAIL] $cfg"; exit 1; fi
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
nm -u "$ko" | sed -E 's/^ +U //; s/\..*$//' | sort -u > "$work/undefined"
awk '{print $2}' "$kdir/Module.symvers" | sort -u > "$work/exports"
comm -23 "$work/undefined" "$work/exports" > "$work/missing"
if [[ -s $work/missing ]]; then
    echo '[FAIL] Symbols absent from exact target Module.symvers:'
    cat "$work/missing"
    exit 1
fi
echo "[PASS] $(wc -l < "$work/undefined") undefined references are exported by the exact target kernel"
if lspci -nn 2>/dev/null | grep -qi '1414:008e'; then echo '[PASS] Hyper-V Basic Render device 1414:008e'; else echo '[WARN] PCI 1414:008e not visible'; fi
if find /sys/bus/vmbus/devices -maxdepth 2 -name class_id -exec grep -liE '6e382d18-3336-4f4b-acc4-2b7703d4df4a|dde9cbc0-5060-4436-9448-ea1254a5d177' {} + 2>/dev/null | grep -q .; then
    echo '[PASS] GPU-P VMBus GUID visible'
else
    echo '[WARN] GPU-P VMBus GUID not visible'
fi
echo '[PASS] static module preflight complete; nothing was loaded or installed'
