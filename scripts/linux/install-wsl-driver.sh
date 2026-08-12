#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: sudo $0 --archive wsl-nvidia-driver.tar.gz --apply"; }
archive=''
apply=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --archive) archive=${2:?}; shift 2 ;;
        --apply) apply=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -f $archive ]] || { echo "Archive not found: $archive" >&2; exit 1; }

mapfile -t unsafe < <(tar -tzf "$archive" | grep -E '(^/|(^|/)\.\.(/|$))' || true)
((${#unsafe[@]} == 0)) || { printf 'Unsafe archive path: %s\n' "${unsafe[@]}" >&2; exit 1; }
tar -tzf "$archive" | grep -q '^usr/lib/wsl/lib/' || { echo 'Archive has no usr/lib/wsl/lib directory.' >&2; exit 1; }

if ((apply == 0)); then
    echo 'Archive structure is valid. Re-run with --apply to install it.'
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tar -xzf "$archive" -C "$tmp"
[[ -x $tmp/usr/lib/wsl/lib/nvidia-smi ]] || { echo 'Archive has no executable nvidia-smi.' >&2; exit 1; }

timestamp=$(date +%Y%m%d-%H%M%S)
backup=''
if [[ -e /usr/lib/wsl ]]; then
    backup="/usr/lib/wsl.before-$timestamp"
    mv /usr/lib/wsl "$backup"
fi
install -d -m 0755 /usr/lib
mv "$tmp/usr/lib/wsl" /usr/lib/wsl
chown -R root:root /usr/lib/wsl
ln -sfn /usr/lib/wsl/lib/nvidia-smi /usr/local/bin/nvidia-smi
ldconfig || true

library_path=/usr/lib/wsl/lib
while IFS= read -r -d '' directory; do
    library_path+="${library_path:+:}$directory"
done < <(find /usr/lib/wsl/drivers -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

if ! LD_LIBRARY_PATH="$library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    /usr/local/bin/nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader; then
    echo 'nvidia-smi validation failed; restoring the previous /usr/lib/wsl.' >&2
    failed="/usr/lib/wsl.failed-$timestamp"
    mv /usr/lib/wsl "$failed"
    if [[ -n $backup ]]; then mv "$backup" /usr/lib/wsl; fi
    rm -f /usr/local/bin/nvidia-smi
    if [[ -x /usr/lib/wsl/lib/nvidia-smi ]]; then
        ln -s /usr/lib/wsl/lib/nvidia-smi /usr/local/bin/nvidia-smi
    fi
    ldconfig || true
    echo "Failed driver tree retained at $failed" >&2
    exit 1
fi
