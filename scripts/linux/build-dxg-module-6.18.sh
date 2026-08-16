#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-dxg-module-6.18.sh --source WSL_KERNEL_TREE [--kernel-release RELEASE]
       [--kernel-build DIR] [--work DIR] [--output DIR] [--jobs N]

Build drivers/hv/dxgkrnl from a Microsoft WSL 6.6 source tree as an external
module for an already prepared Linux 6.18 kernel. The source tree is copied;
the upstream checkout and running system are not modified. No module is loaded
or installed by this script.
EOF
}
source_dir=''
release=$(uname -r)
kdir=''
work=''
output=''
jobs=$(nproc)
while [[ $# -gt 0 ]]; do
    case $1 in
        --source) source_dir=${2:?}; shift 2 ;;
        --kernel-release) release=${2:?}; shift 2 ;;
        --kernel-build) kdir=${2:?}; shift 2 ;;
        --work) work=${2:?}; shift 2 ;;
        --output) output=${2:?}; shift 2 ;;
        --jobs) jobs=${2:?}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n $source_dir ]] || { usage >&2; exit 2; }
[[ $release == 6.18.* ]] || { echo "Refusing untested target kernel: $release" >&2; exit 2; }
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo '--jobs must be positive.' >&2; exit 2; }
: "${kdir:=/usr/src/linux-headers-$release}"
[[ -f $kdir/Makefile && -f $kdir/Module.symvers ]] || {
    echo "Prepared kernel build tree with Module.symvers not found: $kdir" >&2; exit 1;
}
: "${work:=$PWD/dxg-module-$release}"
: "${output:=$PWD/dxg-module-artifacts-$release}"
[[ ! -e $work ]] || { echo "Refusing to overwrite existing work directory: $work" >&2; exit 1; }
[[ ! -e $output ]] || { echo "Refusing to overwrite existing artifact directory: $output" >&2; exit 1; }
mkdir -p "$output"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
"$root/scripts/linux/prepare-dxg-source.sh" --source "$source_dir" --output "$work"
work="$work/drivers/hv/dxgkrnl"

log="$output/build.log"
make -C "$kdir" M="$work" clean
timeout 1800 make -C "$kdir" M="$work" -j"$jobs" modules 2>&1 | tee "$log"
ko="$work/dxgkrnl.ko"
[[ -f $ko ]] || { echo 'dxgkrnl.ko was not produced.' >&2; exit 1; }
cp -f "$ko" "$output/dxgkrnl.ko"
modinfo "$ko" > "$output/modinfo.txt"
sha256sum "$output/dxgkrnl.ko" > "$output/SHA256SUMS"
printf 'Built %s for %s; artifacts: %s\n' "$ko" "$release" "$output"
