#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 --output /mnt/c/path/wsl-nvidia-driver.tar.gz [--apply]"
    echo 'Default: dry-run; inspect the selected payload without creating an archive.'
}

output=''
apply=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --output) output=${2:?}; shift 2 ;;
        --apply) apply=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n $output ]] || { usage >&2; exit 2; }
[[ -d /usr/lib/wsl/lib ]] || { echo '/usr/lib/wsl/lib not found; run this inside an NVIDIA-enabled WSL distribution.' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'python3 is required.' >&2; exit 1; }
command -v sha256sum >/dev/null || { echo 'sha256sum is required.' >&2; exit 1; }

if ((apply == 0)); then
    echo "Dry run: would create $output from:"
    echo '  /usr/lib/wsl/lib'
    if [[ -d /usr/lib/wsl/drivers ]]; then
        find /usr/lib/wsl/drivers -mindepth 1 -maxdepth 1 -type d \( \
            -iname 'nv*.inf_amd64_*' -o -iname '*nvidia*' \) -print |
        while IFS= read -r directory; do
            if find "$directory" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' -o -name 'nvidia-smi' \) -print -quit | grep -q .; then
                printf '  %s\n' "$directory"
            fi
        done
    fi
    echo 'Re-run with --apply to create the archive.'
    exit 0
fi

mkdir -p "$(dirname "$output")"
tmp=$(mktemp -d)
archive_tmp=$(mktemp --tmpdir="$(dirname "$output")" '.wsl-driver.XXXXXX.tar.gz')
cleanup() { rm -rf -- "$tmp" "$archive_tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/usr/lib/wsl"
cp -a /usr/lib/wsl/lib "$tmp/usr/lib/wsl/"

if [[ -d /usr/lib/wsl/drivers ]]; then
    mkdir -p "$tmp/usr/lib/wsl/drivers"
    find /usr/lib/wsl/drivers -mindepth 1 -maxdepth 1 -type d \( \
        -iname 'nv*.inf_amd64_*' -o -iname '*nvidia*' \) -print0 |
    while IFS= read -r -d '' directory; do
        if find "$directory" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' -o -name 'nvidia-smi' \) -print -quit | grep -q .; then
            cp -a "$directory" "$tmp/usr/lib/wsl/drivers/"
        fi
    done
fi

[[ -f $tmp/usr/lib/wsl/lib/nvidia-smi && -x $tmp/usr/lib/wsl/lib/nvidia-smi ]] || {
    echo 'Selected payload has no executable regular usr/lib/wsl/lib/nvidia-smi.' >&2
    exit 1
}

export MANIFEST_CREATED MANIFEST_ROOT="$tmp"
MANIFEST_CREATED=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat

root = Path(os.environ["MANIFEST_ROOT"])
entries = []
payload_paths = [root / "usr", *(root / "usr").rglob("*")]
for path in sorted(payload_paths, key=lambda item: item.relative_to(root).as_posix()):
    relative = path.relative_to(root).as_posix()
    metadata = path.lstat()
    if stat.S_ISDIR(metadata.st_mode):
        entries.append({"path": relative, "type": "directory", "mode": stat.S_IMODE(metadata.st_mode)})
    elif stat.S_ISREG(metadata.st_mode):
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        entries.append({
            "path": relative,
            "type": "file",
            "size": metadata.st_size,
            "sha256": digest.hexdigest(),
            "mode": stat.S_IMODE(metadata.st_mode),
        })
    elif stat.S_ISLNK(metadata.st_mode):
        entries.append({"path": relative, "type": "symlink", "target": os.readlink(path)})
    else:
        raise SystemExit(f"unsupported source member type: {relative}")
manifest = {
    "schema": "hyperv-linux-gpup/wsl-driver-archive/v1",
    "created": os.environ["MANIFEST_CREATED"],
    "source": "local /usr/lib/wsl only",
    "files": entries,
}
(root / "MANIFEST.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY

# --hard-dereference prevents tar hard-link entries; the validator accepts only
# regular files, directories, and confined symbolic links.
tar --hard-dereference -C "$tmp" -czf "$archive_tmp" MANIFEST.json usr
chmod 600 "$archive_tmp"
mv -f -- "$archive_tmp" "$output"
trap - EXIT
rm -rf -- "$tmp"
printf 'Created %s (%s)\n' "$output" "$(du -h "$output" | awk '{print $1}')"
printf 'SHA256 %s  %s\n' "$(sha256sum "$output" | awk '{print $1}')" "$output"
