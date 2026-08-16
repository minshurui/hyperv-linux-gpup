#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: sudo $0 [--apply]"
    echo 'Default: dry-run; show the preserved rollback action.'
}

apply=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --apply) apply=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'python3 is required.' >&2; exit 1; }

state_file=/var/lib/hyperv-linux-gpup/wsl-driver-rollback.json
[[ -f $state_file && ! -L $state_file ]] || { echo "Rollback state not found: $state_file" >&2; exit 1; }

mapfile -t state < <(python3 - "$state_file" <<'PY'
import json
from pathlib import Path
import sys

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if set(value) != {"schema", "installed_at", "backup", "archive"}:
    raise SystemExit("invalid rollback state keys")
if value["schema"] != "hyperv-linux-gpup/wsl-driver-rollback/v1":
    raise SystemExit("unsupported rollback state schema")
backup = value["backup"]
if backup is not None and (not isinstance(backup, str) or not backup.startswith("/usr/lib/wsl.before-") or "/" in backup[len("/usr/lib/"):]):
    raise SystemExit("unsafe rollback backup path")
print(backup or "")
print(value["installed_at"])
PY
)
backup=${state[0]:-}
installed_at=${state[1]:-unknown}

if [[ -n $backup && ! -e $backup && ! -L $backup ]]; then
    echo "Preserved backup is missing: $backup" >&2
    exit 1
fi
if [[ -z $backup ]]; then
    echo "Dry run: installation at $installed_at had no previous /usr/lib/wsl; rollback will remove the installed tree."
else
    echo "Dry run: rollback installation at $installed_at by restoring $backup."
fi
if ((apply == 0)); then
    echo 'Re-run with --apply to perform rollback.'
    exit 0
fi

removed="/usr/lib/wsl.rolled-back-$(date -u +%Y%m%d-%H%M%S)"
if [[ -e /usr/lib/wsl || -L /usr/lib/wsl ]]; then
    mv -- /usr/lib/wsl "$removed"
fi
if [[ -n $backup ]]; then
    if ! mv -- "$backup" /usr/lib/wsl; then
        if [[ -e $removed || -L $removed ]]; then mv -- "$removed" /usr/lib/wsl; fi
        echo 'Rollback failed while restoring backup; installed tree was put back.' >&2
        exit 1
    fi
fi
rm -f -- /usr/local/bin/nvidia-smi
if [[ -x /usr/lib/wsl/lib/nvidia-smi ]]; then
    ln -s /usr/lib/wsl/lib/nvidia-smi /usr/local/bin/nvidia-smi
fi
ldconfig || true
rm -f -- "$state_file"
echo "Rollback complete. Replaced tree retained at $removed"
