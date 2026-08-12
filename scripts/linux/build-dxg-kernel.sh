#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  build-dxg-kernel.sh --source /usr/src/WSL2-Linux-Kernel-6.6.87.2
                       [--base-config /boot/config-$(uname -r)]
                       [--jobs N] [--output DIR]

The script builds Debian kernel packages locally. It does not download or
redistribute a kernel binary. Use a Microsoft WSL2 kernel tag containing
 drivers/hv/dxgkrnl and review its license before redistribution.
EOF
}
source_dir=''
base_config="/boot/config-$(uname -r)"
jobs="$(nproc)"
output=''
while [[ $# -gt 0 ]]; do
    case $1 in
        --source) source_dir=${2:?}; shift 2 ;;
        --base-config) base_config=${2:?}; shift 2 ;;
        --jobs) jobs=${2:?}; shift 2 ;;
        --output) output=${2:?}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ ${EUID} -eq 0 ]] || { echo 'Run as root or use a root-owned build directory.' >&2; exit 1; }
[[ -d $source_dir ]] || { echo "Source directory not found: $source_dir" >&2; exit 1; }
[[ -f $source_dir/Makefile && -d $source_dir/drivers/hv/dxgkrnl ]] || {
    echo 'Source is not a Linux tree containing drivers/hv/dxgkrnl.' >&2; exit 1;
}
[[ -r $base_config ]] || { echo "Base config not found: $base_config" >&2; exit 1; }
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo '--jobs must be a positive integer.' >&2; exit 2; }

if [[ -z $output ]]; then output="$PWD/dxg-kernel-artifacts"; fi
mkdir -p "$output"
output=$(realpath "$output")
source_dir=$(realpath "$source_dir")
cd "$source_dir"
cp "$base_config" .config
# Keep the distribution configuration, changing only the DXG/Hyper-V essentials.
make olddefconfig
scripts/config --enable DXGKRNL
scripts/config --enable HYPERV
scripts/config --enable HYPERV_NET
scripts/config --enable HYPERV_UTILS
scripts/config --module HYPERV_STORAGE
scripts/config --enable BLK_DEV_INITRD
scripts/config --module EXT4_FS
scripts/config --set-str LOCALVERSION '-dxg-hyperv'
# Distribution configs may reference private certificate paths unavailable in
# an upstream source tree. Empty these values for a reproducible local build.
scripts/config --set-str SYSTEM_TRUSTED_KEYS ''
scripts/config --set-str SYSTEM_REVOCATION_KEYS ''
make olddefconfig

version=$(make -s kernelrelease)
[[ $version == *-dxg-hyperv ]] || {
    echo "Unexpected kernel release after configuration: $version" >&2
    exit 1
}
printf 'Building kernel %s with %s jobs\n' "$version" "$jobs"
make -j"$jobs" bindeb-pkg KDEB_PKGVERSION="1.0.$(date +%Y%m%d%H%M)"

find "$(dirname "$source_dir")" -maxdepth 1 -type f -name "*dxg-hyperv*.deb" -exec cp -f {} "$output/" \;
cp .config "$output/config-$version"
sha256sum "$output"/* > "$output/SHA256SUMS"
printf 'Artifacts written to %s\n' "$output"
