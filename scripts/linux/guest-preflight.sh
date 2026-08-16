#!/usr/bin/env bash
set -euo pipefail

fail=0
pass() { printf '[PASS] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; fail=1; }

[[ ${EUID} -eq 0 ]] || fail 'Run as root.'
if [[ $(uname -m) == x86_64 ]]; then
    pass 'x86_64 guest'
else
    fail "Unsupported architecture: $(uname -m)"
fi

if grep -qiE 'Microsoft Corporation|Virtual Machine' /sys/class/dmi/id/sys_vendor 2>/dev/null; then
    pass 'Hyper-V virtual machine detected'
else
    warn 'Hyper-V DMI signature was not detected'
fi

printf 'Kernel: %s\n' "$(uname -r)"
printf 'Distribution: %s\n' "$(. /etc/os-release && echo "$PRETTY_NAME")"

for command in lspci lsinitramfs update-initramfs update-grub grub-reboot git make gcc bc bison flex pahole openssl dpkg-buildpackage; do
    if command -v "$command" >/dev/null 2>&1; then
        pass "command: $command"
    else
        warn "missing command: $command"
    fi
done

if lspci -nn 2>/dev/null | grep -qi '1414:008e'; then
    pass 'Hyper-V GPU-P PCI device 1414:008e detected'
else
    warn 'GPU-P device 1414:008e is absent; configure the Windows host while the VM is off'
fi

if [[ -e /dev/dxg ]]; then
    pass '/dev/dxg exists'
else
    warn '/dev/dxg is absent under the current kernel'
fi

config="/boot/config-$(uname -r)"
if [[ -r $config ]] && grep -q '^CONFIG_DXGKRNL=y' "$config"; then
    pass 'running kernel has CONFIG_DXGKRNL=y'
else
    warn 'running kernel does not expose built-in DXGKRNL'
fi

root_source=$(findmnt -n -o SOURCE /)
root_type=$(findmnt -n -o FSTYPE /)
printf 'Root filesystem: %s (%s)\n' "$root_source" "$root_type"

if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state 2>/dev/null || true
else
    warn 'mokutil not installed; Secure Boot state was not checked'
fi

if command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -qi nvidia; then
    warn 'NVIDIA DKMS is installed. It cannot bind the Microsoft 1414:008e GPU-P device and may fail while installing a custom kernel.'
fi

exit "$fail"
