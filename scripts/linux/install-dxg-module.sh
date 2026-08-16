#!/usr/bin/env bash
set -euo pipefail
usage() { cat <<'EOF'
Usage: install-dxg-module.sh MODULE [--kernel-release RELEASE] [--apply]
Dry-run is the default. With --apply, install a preflighted module to a
kernel-scoped path, create an idempotent systemd service, and preserve rollback.
EOF
}
if [[ ${1:-} == -h || ${1:-} == --help ]]; then usage; exit 0; fi
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
module=$1; shift
release=$(uname -r); apply=0
while [[ $# -gt 0 ]]; do case $1 in
 --kernel-release) release=${2:?}; shift 2;; --apply) apply=1; shift;; -h|--help) usage; exit 0;; *) usage >&2; exit 2;; esac; done
[[ $release == "$(uname -r)" ]] || { echo 'Install only while the target kernel is running.' >&2; exit 1; }
module=$(realpath "$module")
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$script_dir/preflight-dxg-module.sh" "$module"
dest_dir="/usr/local/lib/modules/dxgkrnl/$release"
dest="$dest_dir/dxgkrnl.ko"
state="/var/lib/hyperv-linux-gpup/$release"
echo "Would install $module -> $dest"
echo 'Would install hyperv-linux-gpup-dxg.service and enable it.'
[[ $apply -eq 1 ]] || { echo 'Dry-run only; pass --apply to modify the system.'; exit 0; }
[[ $EUID -eq 0 ]] || { echo 'Run as root for --apply.' >&2; exit 1; }
command -v flock >/dev/null || { echo 'flock is required.' >&2; exit 1; }
mkdir -p /var/lock
exec 9>/var/lock/hyperv-linux-gpup-install.lock
flock -n 9 || { echo 'Another install operation is active.' >&2; exit 1; }
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
install -m 0644 "$module" "$stage/dxgkrnl.ko"
mkdir -p "$dest_dir" "$state/backups"
if [[ -e $dest ]]; then cp -a "$dest" "$state/backups/dxgkrnl.ko.$(date -u +%Y%m%dT%H%M%SZ)"; fi
install -m 0644 "$stage/dxgkrnl.ko" "$dest.new"
mv -f "$dest.new" "$dest"
sha256sum "$dest" > "$state/installed.sha256"
printf '%s\n' "$release" > "$state/kernel-release"
cat > /usr/local/sbin/hyperv-linux-gpup-dxg-load <<EOF
#!/usr/bin/env bash
set -euo pipefail
grep -q '^dxgkrnl ' /proc/modules && exit 0
exec /sbin/insmod '$dest'
EOF
cat > /usr/local/sbin/hyperv-linux-gpup-dxg-unload <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
grep -q '^dxgkrnl ' /proc/modules || exit 0
if command -v fuser >/dev/null && fuser /dev/dxg >/dev/null 2>&1; then
  echo '/dev/dxg is in use; refusing unload.' >&2; exit 1
fi
exec /sbin/rmmod dxgkrnl
EOF
chmod 0755 /usr/local/sbin/hyperv-linux-gpup-dxg-load /usr/local/sbin/hyperv-linux-gpup-dxg-unload
cat > /etc/systemd/system/hyperv-linux-gpup-dxg.service <<'EOF'
[Unit]
Description=Hyper-V GPU-P dxgkrnl external module
ConditionPathExists=/sys/bus/vmbus
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/hyperv-linux-gpup-dxg-load
ExecStop=/usr/local/sbin/hyperv-linux-gpup-dxg-unload
TimeoutStartSec=30
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/hyperv-linux-gpup-dxg.service
systemctl enable --now hyperv-linux-gpup-dxg.service
for _ in {1..30}; do [[ -e /dev/dxg ]] && break; sleep 1; done
[[ -e /dev/dxg ]] || { echo '/dev/dxg did not appear.' >&2; exit 1; }
echo "Installed and loaded $dest"
