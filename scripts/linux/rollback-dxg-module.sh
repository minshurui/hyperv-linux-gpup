#!/usr/bin/env bash
set -Eeuo pipefail

usage() { cat <<'EOF'
Usage: rollback-dxg-module.sh [--kernel-release RELEASE] [--transaction DIR] [--apply]
Dry-run is the default. Without --transaction, restore the snapshot captured by
the current committed install transaction, including loader/unit/service state.
EOF
}

release=$(uname -r); transaction=''; apply=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --kernel-release) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; release=$2; shift 2 ;;
        --transaction) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; transaction=$2; shift 2 ;;
        --apply) apply=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ $release == "$(uname -r)" ]] || { echo 'Rollback only while the target kernel is running.' >&2; exit 1; }
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/linux/dxg-module-lifecycle-common.sh
source "$script_dir/dxg-module-lifecycle-common.sh"
export DXG_RELEASE=$release
export DXG_DEST="${DXG_ROOT}/usr/local/lib/modules/dxgkrnl/$release/dxgkrnl.ko"

if [[ -z $transaction ]]; then transaction=$(_dxg_current_transaction "$release"); fi
transaction=$(realpath "$transaction")
case $transaction in
    "$DXG_STATE_ROOT/$release/transactions/"*) ;;
    *) _dxg_die 'Transaction must be from the target kernel state directory.' ;;
esac
_dxg_validate_transaction "$transaction" "$release"

echo "Would restore immutable transaction snapshot: $transaction"
echo "Would stop and confirm dxgkrnl unloaded before replacing files."
[[ $apply -eq 1 ]] || { echo 'Dry-run only; pass --apply.'; exit 0; }

_dxg_require_apply_root
_dxg_lock
DXG_TX=$(_dxg_new_transaction "$release" rollback)
trap '_dxg_err_rollback $LINENO' ERR
_dxg_restore_snapshot "$transaction"
_dxg_fault after-restore
previous=$(_dxg_state_value "$transaction/meta" previous)
if [[ -n $previous ]]; then _dxg_set_current "$release" "$previous"; else _dxg_clear_current "$release"; fi
_dxg_seal_transaction "$DXG_TX" committed
trap - ERR
echo "Restored $transaction"
echo "Rollback transaction: $DXG_TX"
