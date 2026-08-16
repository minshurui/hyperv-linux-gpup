#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo 'Usage: install-fnos-mediasrv-compat.sh ADAPTER.so [--apply]' >&2
}
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 64; }
source_so=$(readlink -f "$1")
apply=false
[[ ${2:-} == --apply ]] && apply=true
[[ ${2:-} == '' || ${2:-} == --apply ]] || { usage; exit 64; }
[[ -f $source_so ]] || { echo "not found: $source_so" >&2; exit 1; }
command -v nm >/dev/null
if nm -D "$source_so" | grep -Eq ' (cu[A-Za-z0-9_]*|NvEncode[A-Za-z0-9_]*|dlsym)$'; then
    echo 'refusing CUDA, NVENC, or dlsym interposer' >&2
    exit 1
fi
nm -D "$source_so" | grep -Eq ' (access|open|open64|readdir|readdir64|realpath)$'

install_dir=/usr/local/lib/fnos-mediasrv-gpup
target="$install_dir/fnos-mediasrv-gpup-compat.so"
dropin_dir=/etc/systemd/system/mediasrv.service.d
dropin="$dropin_dir/90-gpup-compat.conf"
backup_root=/var/lib/fnos-mediasrv-gpup/backups
stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup="$backup_root/$stamp.UNALLOCATED"

cat <<EOF
Plan:
  install trusted local input $source_so -> $target
  set LD_PRELOAD only for mediasrv.service
  restart and verify mediasrv
  create a unique snapshot under $backup_root
EOF
$apply || { echo 'Dry-run only; add --apply to modify the system.'; exit 0; }

mkdir -p "$backup_root" "$install_dir" "$dropin_dir"
backup=$(mktemp -d "$backup_root/$stamp.XXXXXX")
[[ -f $target ]] && cp -a "$target" "$backup/adapter.so"
[[ -f $dropin ]] && cp -a "$dropin" "$backup/dropin.conf"
printf '%s\n' "target_present=$([[ -f $target ]] && echo yes || echo no)" \
    "dropin_present=$([[ -f $dropin ]] && echo yes || echo no)" >"$backup/state"
rollback() {
    set +e
    if grep -q '^target_present=yes$' "$backup/state"; then cp -a "$backup/adapter.so" "$target"; else rm -f "$target"; fi
    if grep -q '^dropin_present=yes$' "$backup/state"; then cp -a "$backup/dropin.conf" "$dropin"; else rm -f "$dropin"; fi
    systemctl daemon-reload
    systemctl restart mediasrv
}
on_error() {
    local rc=$?
    echo "installation failed; restoring $backup" >&2
    rollback
    exit "$rc"
}
trap on_error ERR
install -m 0555 "$source_so" "$target.tmp"
mv -f "$target.tmp" "$target"
printf '[Service]\nEnvironment=LD_PRELOAD=%s\n' "$target" >"$dropin.tmp"
chmod 0644 "$dropin.tmp"
mv -f "$dropin.tmp" "$dropin"
systemctl daemon-reload
systemctl restart mediasrv
timeout 45 bash -c 'until systemctl is-active --quiet mediasrv && test -S /var/run/mediasrv.socket; do sleep 1; done'
pid=$(systemctl show mediasrv -p MainPID --value)
grep -F "$target" "/proc/$pid/maps" >/dev/null
systemctl show mediasrv -p ActiveState -p SubState -p NRestarts -p Environment
trap - ERR
echo "Installed. Roll back with: scripts/linux/rollback-fnos-mediasrv-compat.sh $backup --apply"
