#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: sudo $0 --kernel-version VERSION [--mode once|default|rollback] [--apply]"; }
version=''
mode='once'
apply=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --kernel-version) version=${2:?}; shift 2 ;;
        --mode) mode=${2:?}; shift 2 ;;
        --apply) apply=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ $mode =~ ^(once|default|rollback)$ ]] || { usage >&2; exit 2; }
[[ -n $version ]] || { usage >&2; exit 2; }
[[ -f /boot/vmlinuz-$version ]] || { echo "Kernel not installed: $version" >&2; exit 1; }

# Parse the generated menu titles instead of assuming English labels.
entry=$(awk -F"'" -v needle="with Linux $version" '
    /^[[:space:]]*menuentry / && index($2, needle) && $2 !~ /recovery mode/ { print $2; exit }
' /boot/grub/grub.cfg)
submenu=$(awk -F"'" '/^[[:space:]]*submenu / { print $2; exit }' /boot/grub/grub.cfg)
[[ -n $entry ]] || { echo "GRUB entry not found for $version; run update-grub." >&2; exit 1; }
if [[ -n $submenu ]]; then grub_entry="$submenu>$entry"; else grub_entry="$entry"; fi
printf 'Target GRUB entry: %s\nMode: %s\n' "$grub_entry" "$mode"
if [[ $mode != once ]] && ! grep -Eq '^GRUB_DEFAULT=(saved|"saved")$' /etc/default/grub; then
    echo 'Refusing persistent selection: /etc/default/grub must contain GRUB_DEFAULT=saved.' >&2
    exit 1
fi
((apply == 1)) || { echo 'Dry run. Add --apply to change GRUB environment.'; exit 0; }

case $mode in
    once) grub-reboot "$grub_entry" ;;
    default) grub-set-default "$grub_entry" ;;
    rollback)
        fallback=$(awk -F"'" -v excluded="with Linux $version" '
            /^[[:space:]]*menuentry / && /with Linux/ && index($2, excluded) == 0 && $2 !~ /recovery mode/ { print $2; exit }
        ' /boot/grub/grub.cfg)
        [[ -n $fallback ]] || { echo 'No fallback kernel entry found.' >&2; exit 1; }
        if [[ -n $submenu ]]; then fallback="$submenu>$fallback"; fi
        grub-set-default "$fallback"
        ;;
esac
grub-editenv list
