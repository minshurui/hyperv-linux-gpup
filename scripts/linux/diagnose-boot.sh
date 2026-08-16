#!/usr/bin/env bash
set -euo pipefail

boot=${1:--1}
mkdir -p "${2:-./state}"
out="${2:-./state}/boot-diagnose-$(date +%Y%m%d-%H%M%S).log"
{
    echo "=== collected $(date -Is) ==="
    echo '=== kernel ==='; uname -a
    echo '=== cmdline ==='; cat /proc/cmdline
    echo '=== dxg/hyperv dmesg ==='; dmesg | grep -iE 'dxg|hyper-v|hyperv|netvsc|mmio|1414:008e' || true
    echo '=== device ==='; ls -l /dev/dxg 2>&1 || true
    echo '=== PCI ==='; lspci -nn 2>&1 || true
    echo '=== failed units ==='; systemctl --failed --no-pager 2>&1 || true
    echo '=== ordering warnings ==='; journalctl -b "$boot" -p warning..alert --no-pager 2>&1 || true
    echo '=== network ==='; ip addr 2>&1 || true; ip route 2>&1 || true
} | tee "$out"
echo "Saved: $out"
