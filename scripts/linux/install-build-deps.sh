#!/usr/bin/env bash
set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ ${1:-} == --apply ]] || {
    echo 'Dry run. Re-run with --apply to install Debian/Ubuntu build dependencies.'
    exit 0
}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    bc binutils bison build-essential cpio dwarves fakeroot flex git kmod \
    libelf-dev libncurses-dev libssl-dev lz4 rsync wget xz-utils zstd \
    dpkg-dev debhelper initramfs-tools grub-common pciutils mokutil
