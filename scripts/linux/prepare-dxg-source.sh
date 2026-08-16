#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: prepare-dxg-source.sh --source WSL_KERNEL_TREE --output DIR

Copy and patch the exact tested Microsoft dxgkrnl source. The input must match
linux-msft-wsl-6.6.87.2 (427645e3db3a8896714f22a3d3fe0c3f7b317ad4)
by every recorded file hash. An existing output directory is never overwritten.
EOF
}

source_dir=''
output=''
while [[ $# -gt 0 ]]; do
    case $1 in
        --source) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; source_dir=$2; shift 2 ;;
        --output) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; output=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n $source_dir && -n $output ]] || { usage >&2; exit 2; }
[[ -d $source_dir ]] || { echo "Source tree not found: $source_dir" >&2; exit 1; }
[[ ! -e $output ]] || { echo "Refusing to overwrite existing output: $output" >&2; exit 1; }
for tool in patch python3 sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Required command not found: $tool" >&2; exit 1; }
done

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
patch_dir="$root/patches/dxgkrnl/6.6-to-6.18"
series="$patch_dir/series"
manifest="$patch_dir/provenance.json"
[[ -f $series && -f $manifest ]] || { echo "Patch series or provenance manifest not found: $patch_dir" >&2; exit 1; }

python3 - "$source_dir" "$patch_dir" "$manifest" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

source, patch_dir, manifest_path = map(Path, sys.argv[1:])
try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_files = manifest["source"]["files"]
    expected_patches = manifest["patch_series"]["patches"]
    expected_series = manifest["patch_series"]["series_sha256"]
except (KeyError, json.JSONDecodeError) as exc:
    raise SystemExit(f"Invalid provenance manifest: {exc}")

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

failures = []
for relative, expected in expected_files.items():
    path = source / relative
    if not path.is_file():
        failures.append(f"missing source file: {relative}")
    elif digest(path) != expected:
        failures.append(f"source hash mismatch: {relative}")
if digest(patch_dir / "series") != expected_series:
    failures.append("patch series hash mismatch: series")
series_names = [line.strip() for line in (patch_dir / "series").read_text().splitlines()
                if line.strip() and not line.lstrip().startswith("#")]
manifest_names = [entry["file"] for entry in expected_patches]
if series_names != manifest_names:
    failures.append("series order does not match provenance manifest")
for entry in expected_patches:
    path = patch_dir / entry["file"]
    if not path.is_file() or digest(path) != entry["sha256"]:
        failures.append(f"patch hash mismatch: {entry['file']}")
if failures:
    raise SystemExit("Provenance verification failed:\n  " + "\n  ".join(failures))
PY

if [[ -e $source_dir/.git ]]; then
    command -v git >/dev/null 2>&1 || { echo 'git is required to verify this checkout.' >&2; exit 1; }
    actual_commit=$(git -C "$source_dir" rev-parse HEAD)
    [[ $actual_commit == 427645e3db3a8896714f22a3d3fe0c3f7b317ad4 ]] || {
        echo "Unexpected source commit: $actual_commit" >&2; exit 1;
    }
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/prepare-dxg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/drivers/hv" "$stage/include/uapi/misc"
cp -a "$source_dir/drivers/hv/dxgkrnl" "$stage/drivers/hv/"
cp -a "$source_dir/include/uapi/misc/d3dkmthk.h" "$stage/include/uapi/misc/"

patch_count=0
while IFS= read -r patch_name || [[ -n $patch_name ]]; do
    [[ -n $patch_name && $patch_name != \#* ]] || continue
    [[ $patch_name != */* && -f $patch_dir/$patch_name ]] || {
        echo "Invalid patch series entry: $patch_name" >&2; exit 1;
    }
    patch --directory="$stage" --strip=1 --fuzz=0 --batch --forward \
        < "$patch_dir/$patch_name"
    ((patch_count += 1))
done < "$series"
[[ $patch_count -eq 5 ]] || { echo "Expected exactly 5 patches, found $patch_count" >&2; exit 1; }

module="$stage/drivers/hv/dxgkrnl"
mkdir -p "$module/include/uapi/misc"
mv "$stage/include/uapi/misc/d3dkmthk.h" "$module/include/uapi/misc/"
makefile="$module/Makefile"
python3 - "$makefile" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old_obj = "obj-$(CONFIG_DXGKRNL)\t+= dxgkrnl.o"
old_list = "dxgkrnl-y :="
if s.count(old_obj) != 1 or s.count(old_list) != 1:
    raise SystemExit("Makefile external-module anchors did not match exactly")
s = s.replace(old_obj, "obj-m += dxgkrnl.o", 1)
s = s.replace(old_list, "dxgkrnl-objs :=", 1)
s += "\nccflags-y += -I$(src)/include\n"
p.write_text(s, encoding="utf-8")
PY

# Rename only after all verification and patching succeeds, so failure leaves no
# partial output that a later build could mistake for prepared source.
mv "$stage" "$output"
trap - EXIT
printf 'Prepared exact dxgkrnl source in %s using %d patches.\n' "$output" "$patch_count"
