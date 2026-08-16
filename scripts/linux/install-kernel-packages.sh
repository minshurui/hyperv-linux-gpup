#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: sudo $0 --directory /path/to/debs --kernel-version VERSION --apply"; }
directory=''
version=''
apply=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --directory) directory=${2:?}; shift 2 ;;
        --kernel-version) version=${2:?}; shift 2 ;;
        --apply) apply=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -d $directory && -n $version ]] || { usage >&2; exit 2; }

mapfile -t packages < <(find "$directory" -maxdepth 1 -type f -name "*${version}*.deb" -print | sort)
((${#packages[@]} > 0)) || { echo "No package matching $version in $directory" >&2; exit 1; }
printf 'Packages:\n'; printf '  %s\n' "${packages[@]}"
((apply == 1)) || { echo 'Dry run. Add --apply to install without changing the current default kernel.'; exit 0; }

dpkg -i "${packages[@]}" || apt-get -f install -y
depmod -a "$version"
[[ -f /boot/initrd.img-$version ]] || update-initramfs -c -k "$version"
update-grub
[[ -f /boot/vmlinuz-$version ]] || { echo 'Kernel image was not installed.' >&2; exit 1; }
grep -q '^CONFIG_DXGKRNL=y' "/boot/config-$version" || { echo 'Installed kernel does not have CONFIG_DXGKRNL=y.' >&2; exit 1; }
echo "Installed $version. The current/default kernel was not changed."
echo "Next: sudo scripts/linux/set-grub-kernel.sh --kernel-version '$version' --mode once --apply"
