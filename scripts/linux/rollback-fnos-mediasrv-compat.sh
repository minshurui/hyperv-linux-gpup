#!/usr/bin/env bash
set -euo pipefail
usage(){ echo 'Usage: rollback-fnos-mediasrv-compat.sh BACKUP-DIR [--apply]' >&2; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 64; }
backup=$(readlink -f "$1"); apply=false
[[ ${2:-} == --apply ]] && apply=true
[[ ${2:-} == '' || ${2:-} == --apply ]] || { usage; exit 64; }
[[ -f $backup/state ]] || { echo "invalid backup: $backup" >&2; exit 1; }
case "$backup" in /var/lib/fnos-mediasrv-gpup/backups/*) ;; *) echo 'backup outside managed root' >&2; exit 1;; esac
target=/usr/local/lib/fnos-mediasrv-gpup/fnos-mediasrv-gpup-compat.so
dropin=/etc/systemd/system/mediasrv.service.d/90-gpup-compat.conf
cat <<EOF
Plan:
  restore adapter and drop-in state from $backup
  restart and verify mediasrv
EOF
$apply || { echo 'Dry-run only; add --apply to modify the system.'; exit 0; }
if grep -q '^target_present=yes$' "$backup/state"; then install -m 0555 "$backup/adapter.so" "$target"; else rm -f "$target"; fi
if grep -q '^dropin_present=yes$' "$backup/state"; then install -m 0644 "$backup/dropin.conf" "$dropin"; else rm -f "$dropin"; fi
systemctl daemon-reload
systemctl restart mediasrv
timeout 45 bash -c 'until systemctl is-active --quiet mediasrv && test -S /var/run/mediasrv.socket; do sleep 1; done'
if grep -q '^dropin_present=no$' "$backup/state"; then
    pid=$(systemctl show mediasrv -p MainPID --value)
    if grep -F 'fnos-mediasrv-gpup-compat.so' "/proc/$pid/maps"; then
        echo 'adapter still loaded after rollback' >&2
        exit 1
    fi
fi
systemctl show mediasrv -p ActiveState -p SubState -p NRestarts -p Environment
echo "Rolled back from $backup"
