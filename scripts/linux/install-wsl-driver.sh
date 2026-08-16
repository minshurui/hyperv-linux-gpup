#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: sudo $0 --archive wsl-nvidia-driver.tar.gz [--apply]"
    echo 'Default: validate only; --apply installs from a validated secure staging tree.'
}

archive=''
apply=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --archive) archive=${2:?}; shift 2 ;;
        --apply) apply=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -n $archive && -f $archive ]] || { echo "Archive not found: $archive" >&2; exit 1; }
command -v python3 >/dev/null || { echo 'python3 is required.' >&2; exit 1; }

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
validator="$script_dir/validate-wsl-driver-archive.py"
[[ -f $validator ]] || { echo "Validator not found: $validator" >&2; exit 1; }
archive=$(readlink -f -- "$archive")

python3 "$validator" "$archive"
if ((apply == 0)); then
    echo 'Dry run complete. Re-run with --apply to install this archive.'
    exit 0
fi

install -d -m 0700 /usr/lib/.wsl-driver-staging
staging=$(mktemp -d /usr/lib/.wsl-driver-staging/install.XXXXXXXX)
cleanup() { rm -rf -- "$staging"; }
trap cleanup EXIT
python3 "$validator" "$archive" --extract "$staging"
[[ -f $staging/usr/lib/wsl/lib/nvidia-smi && -x $staging/usr/lib/wsl/lib/nvidia-smi ]] || {
    echo 'Validated staging tree has no executable regular nvidia-smi.' >&2
    exit 1
}
chown -hR root:root "$staging/usr/lib/wsl"

state_dir=/var/lib/hyperv-linux-gpup
state_file=$state_dir/wsl-driver-rollback.json
install -d -m 0700 "$state_dir"
if [[ -e $state_file || -L $state_file ]]; then
    echo "A preserved rollback is already recorded at $state_file." >&2
    echo "Run rollback-wsl-driver.sh --apply, or move that state file aside after reviewing it." >&2
    exit 1
fi

timestamp=$(date -u +%Y%m%d-%H%M%S)
backup=''
if [[ -e /usr/lib/wsl || -L /usr/lib/wsl ]]; then
    backup="/usr/lib/wsl.before-$timestamp"
    [[ ! -e $backup && ! -L $backup ]] || { echo "Backup path already exists: $backup" >&2; exit 1; }
    mv -- /usr/lib/wsl "$backup"
fi

rollback_install() {
    local failed="/usr/lib/wsl.failed-$timestamp"
    if [[ -e /usr/lib/wsl || -L /usr/lib/wsl ]]; then mv -- /usr/lib/wsl "$failed"; fi
    if [[ -n $backup && ( -e $backup || -L $backup ) ]]; then mv -- "$backup" /usr/lib/wsl; fi
    rm -f -- /usr/local/bin/nvidia-smi
    if [[ -x /usr/lib/wsl/lib/nvidia-smi ]]; then
        ln -s /usr/lib/wsl/lib/nvidia-smi /usr/local/bin/nvidia-smi
    fi
    ldconfig || true
    echo "Installation failed; previous tree restored. Failed tree retained at $failed" >&2
}
trap 'rollback_install; cleanup' ERR
mv -- "$staging/usr/lib/wsl" /usr/lib/wsl
ln -sfn /usr/lib/wsl/lib/nvidia-smi /usr/local/bin/nvidia-smi
ldconfig || true

library_path=/usr/lib/wsl/lib
while IFS= read -r -d '' directory; do
    library_path+="${library_path:+:}$directory"
done < <(find /usr/lib/wsl/drivers -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

LD_LIBRARY_PATH="$library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    /usr/local/bin/nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader

state_tmp=$(mktemp "$state_dir/.wsl-driver-rollback.XXXXXXXX")
rm -f -- "$state_tmp"
python3 - "$state_tmp" "$backup" "$archive" "$timestamp" <<'PY'
import json
from pathlib import Path
import sys

path, backup, archive, timestamp = sys.argv[1:]
value = {
    "schema": "hyperv-linux-gpup/wsl-driver-rollback/v1",
    "installed_at": timestamp,
    "backup": backup or None,
    "archive": archive,
}
Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
chmod 600 "$state_tmp"
mv -- "$state_tmp" "$state_file"
trap - ERR EXIT
rm -rf -- "$staging"
echo "Installed validated WSL driver tree. Rollback state: $state_file"
echo "Rollback command: sudo $script_dir/rollback-wsl-driver.sh --apply"
