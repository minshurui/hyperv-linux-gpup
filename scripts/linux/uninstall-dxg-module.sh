#!/usr/bin/env bash
set -Eeuo pipefail

usage() { cat <<'EOF'
Usage: uninstall-dxg-module.sh [--kernel-release RELEASE] [--apply]
Dry-run is the default. Safe uninstall disables/stops the managed service,
confirms dxgkrnl is unloaded, removes only managed files, and keeps immutable
transaction history so the uninstall itself can be audited or rolled back.
EOF
}

release=$(uname -r); apply=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --kernel-release) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; release=$2; shift 2 ;;
        --apply) apply=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ $release == "$(uname -r)" ]] || { echo 'Uninstall only while the target kernel is running.' >&2; exit 1; }
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/linux/dxg-module-lifecycle-common.sh
source "$script_dir/dxg-module-lifecycle-common.sh"
export DXG_RELEASE=$release
DXG_DEST="${DXG_ROOT}/usr/local/lib/modules/dxgkrnl/$release/dxgkrnl.ko"

managed=$(_dxg_current_transaction "$release")
_dxg_validate_transaction "$managed" "$release"
for required in "$DXG_DEST" "$DXG_LOADER" "$DXG_UNLOADER" "$DXG_UNIT_FILE"; do
    [[ -e $required || -L $required ]] || _dxg_die "Managed file is missing; refusing partial uninstall: $required"
done

echo "Would safely uninstall the current dxg lifecycle from kernel $release."
echo "Would preserve immutable transaction history under $DXG_STATE_ROOT/$release/transactions."
[[ $apply -eq 1 ]] || { echo 'Dry-run only; pass --apply.'; exit 0; }

_dxg_require_apply_root
_dxg_lock
DXG_TX=$(_dxg_new_transaction "$release" uninstall)
trap '_dxg_err_rollback $LINENO' ERR
_dxg_stop_and_confirm_unloaded
_dxg_fault after-stop
systemctl disable "$DXG_UNIT"
rm -f "$DXG_DEST" "$DXG_LOADER" "$DXG_UNLOADER" "$DXG_UNIT_FILE"
_dxg_fault after-remove
systemctl daemon-reload
_dxg_clear_current "$release"
_dxg_seal_transaction "$DXG_TX" committed
trap - ERR
echo "Uninstalled dxg module lifecycle for $release"
echo "Transaction: $DXG_TX"
