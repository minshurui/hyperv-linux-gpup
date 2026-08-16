#!/usr/bin/env bash
set -euo pipefail
usage() { echo "Usage: $0 [--kernel-release RELEASE] [--backup FILE] [--apply]"; }
release=$(uname -r); backup=''; apply=0
while [[ $# -gt 0 ]]; do case $1 in
 --kernel-release) release=${2:?}; shift 2;; --backup) backup=${2:?}; shift 2;; --apply) apply=1; shift;; -h|--help) usage; exit 0;; *) usage >&2; exit 2;; esac; done
state="/var/lib/hyperv-linux-gpup/$release"
dest="/usr/local/lib/modules/dxgkrnl/$release/dxgkrnl.ko"
if [[ -z $backup ]]; then
  echo "Available backups in $state/backups:"
  find "$state/backups" -maxdepth 1 -type f -name 'dxgkrnl.ko.*' -print 2>/dev/null | sort
  echo 'Select one explicitly with --backup.'
  exit 0
fi
backup=$(realpath "$backup")
case $backup in "$state"/backups/*) ;; *) echo 'Backup must be from the kernel state directory.' >&2; exit 1;; esac
[[ -r $backup ]] || { echo 'Backup is not readable.' >&2; exit 1; }
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$script_dir/preflight-dxg-module.sh" "$backup"
echo "Would restore $backup -> $dest"
[[ $apply -eq 1 ]] || { echo 'Dry-run only; pass --apply.'; exit 0; }
[[ $EUID -eq 0 ]] || { echo 'Run as root for --apply.' >&2; exit 1; }
if command -v fuser >/dev/null && fuser /dev/dxg >/dev/null 2>&1; then
  echo '/dev/dxg is in use; stop consumers before rollback.' >&2; exit 1
fi
was_active=$(systemctl is-active hyperv-linux-gpup-dxg.service 2>/dev/null || true)
systemctl stop hyperv-linux-gpup-dxg.service 2>/dev/null || true
cp -a "$dest" "$state/backups/dxgkrnl.ko.pre-rollback.$(date -u +%Y%m%dT%H%M%SZ)"
install -m 0644 "$backup" "$dest.new"
mv -f "$dest.new" "$dest"
sha256sum "$dest" > "$state/installed.sha256"
if [[ $was_active == active ]]; then systemctl start hyperv-linux-gpup-dxg.service; fi
echo "Restored $backup"
