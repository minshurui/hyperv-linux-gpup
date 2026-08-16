#!/usr/bin/env bash
set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
apply=0
[[ ${1:-} == --apply ]] && apply=1
file=/etc/default/grub
[[ -f $file ]] || { echo "$file not found." >&2; exit 1; }

current=$(grep -E '^GRUB_DEFAULT=' "$file" | tail -1 || true)
printf 'Current: %s\n' "${current:-<unset>}"
if [[ $current == 'GRUB_DEFAULT=saved' || $current == 'GRUB_DEFAULT="saved"' ]]; then
    echo 'GRUB saved-default mode is already enabled.'
    exit 0
fi
((apply == 1)) || { echo 'Dry run. Re-run with --apply to back up the file and enable GRUB_DEFAULT=saved.'; exit 0; }

backup="$file.before-dxg-$(date +%Y%m%d-%H%M%S)"
cp -a "$file" "$backup"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
awk '
    BEGIN { changed=0 }
    /^GRUB_DEFAULT=/ && changed == 0 { print "GRUB_DEFAULT=saved"; changed=1; next }
    { print }
    END { if (changed == 0) print "GRUB_DEFAULT=saved" }
' "$file" > "$tmp"
install -m 0644 "$tmp" "$file"
update-grub
echo "Enabled GRUB_DEFAULT=saved; backup: $backup"
