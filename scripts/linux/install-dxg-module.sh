#!/usr/bin/env bash
set -Eeuo pipefail

usage() { cat <<'EOF'
Usage: install-dxg-module.sh MODULE [--kernel-release RELEASE] [--apply]
Dry-run is the default. With --apply, transactionally replace the module,
loader scripts, and systemd unit. Any error restores the exact prior state.
EOF
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then usage; exit 0; fi
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
module=$1; shift
release=$(uname -r); apply=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --kernel-release) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; release=$2; shift 2 ;;
        --apply) apply=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ $release == "$(uname -r)" ]] || { echo 'Install only while the target kernel is running.' >&2; exit 1; }
module=$(realpath "$module")
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$script_dir/preflight-dxg-module.sh" "$module"
# shellcheck source=scripts/linux/dxg-module-lifecycle-common.sh
source "$script_dir/dxg-module-lifecycle-common.sh"

export DXG_RELEASE=$release
DXG_DEST_DIR="${DXG_ROOT}/usr/local/lib/modules/dxgkrnl/$release"
DXG_DEST="$DXG_DEST_DIR/dxgkrnl.ko"

echo "Would transactionally install $module -> $DXG_DEST"
echo "Would replace $DXG_LOADER, $DXG_UNLOADER, and $DXG_UNIT_FILE."
echo "Would preserve module/loader/unit bytes plus enabled, active, and loaded state."
[[ $apply -eq 1 ]] || { echo 'Dry-run only; pass --apply to modify the system.'; exit 0; }

_dxg_require_apply_root
_dxg_lock
DXG_TX=$(_dxg_new_transaction "$release" install)
trap '_dxg_err_rollback $LINENO' ERR

_dxg_stop_and_confirm_unloaded
_dxg_fault after-stop

loader_content=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
grep -q '^dxgkrnl ' /proc/modules && exit 0
exec /sbin/insmod '$DXG_DEST'
EOF
)
unloader_content=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
grep -q '^dxgkrnl ' /proc/modules || exit 0
if command -v fuser >/dev/null && fuser /dev/dxg >/dev/null 2>&1; then
    echo '/dev/dxg is in use; refusing unload.' >&2
    exit 1
fi
/sbin/rmmod dxgkrnl
grep -q '^dxgkrnl ' /proc/modules && { echo 'dxgkrnl remained loaded after rmmod.' >&2; exit 1; }
EOF
)
unit_content=$(cat <<'EOF'
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
)

_dxg_atomic_copy "$module" "$DXG_DEST" 0644
_dxg_fault after-module
_dxg_atomic_text "$DXG_LOADER" 0755 "$loader_content"$'\n'
_dxg_atomic_text "$DXG_UNLOADER" 0755 "$unloader_content"$'\n'
_dxg_fault after-loaders
_dxg_atomic_text "$DXG_UNIT_FILE" 0644 "$unit_content"$'\n'
_dxg_fault after-unit
systemctl daemon-reload
systemd-analyze verify "$DXG_UNIT_FILE"
systemctl enable "$DXG_UNIT"
systemctl start "$DXG_UNIT"
_dxg_fault after-start
_dxg_module_loaded || _dxg_die 'dxgkrnl did not load.'
if [[ ${DXG_SKIP_DEVICE_WAIT:-0} != 1 ]]; then
    for _ in {1..30}; do [[ -e ${DXG_ROOT}/dev/dxg ]] && break; sleep 1; done
    [[ -e ${DXG_ROOT}/dev/dxg ]] || _dxg_die '/dev/dxg did not appear.'
fi

_dxg_set_current "$release" "${DXG_TX##*/}"
_dxg_seal_transaction "$DXG_TX" committed
trap - ERR
echo "Installed and loaded $DXG_DEST"
echo "Transaction: $DXG_TX"
