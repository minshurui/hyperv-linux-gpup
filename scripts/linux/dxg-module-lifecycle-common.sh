#!/usr/bin/env bash
# Shared transactional lifecycle helpers for dxg module install/rollback/uninstall.
# This file is sourced by the entry-point scripts.

DXG_UNIT=${DXG_UNIT:-hyperv-linux-gpup-dxg.service}
DXG_ROOT=${DXG_ROOT:-}
DXG_PROC_MODULES=${DXG_PROC_MODULES:-${DXG_ROOT}/proc/modules}
DXG_LOCK_FILE=${DXG_LOCK_FILE:-${DXG_ROOT}/var/lock/hyperv-linux-gpup-dxg.lock}
DXG_STATE_ROOT=${DXG_STATE_ROOT:-${DXG_ROOT}/var/lib/hyperv-linux-gpup}
DXG_LOADER=${DXG_LOADER:-${DXG_ROOT}/usr/local/sbin/hyperv-linux-gpup-dxg-load}
DXG_UNLOADER=${DXG_UNLOADER:-${DXG_ROOT}/usr/local/sbin/hyperv-linux-gpup-dxg-unload}
DXG_UNIT_FILE=${DXG_UNIT_FILE:-${DXG_ROOT}/etc/systemd/system/${DXG_UNIT}}

_dxg_log() { printf '%s\n' "$*"; }
_dxg_die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

_dxg_require_apply_root() {
    [[ ${DXG_ALLOW_NON_ROOT:-0} == 1 || $EUID -eq 0 ]] || _dxg_die 'Run as root for --apply.'
    command -v flock >/dev/null 2>&1 || _dxg_die 'flock is required.'
}

_dxg_lock() {
    mkdir -p "$(dirname "$DXG_LOCK_FILE")"
    exec 9>"$DXG_LOCK_FILE"
    flock -n 9 || _dxg_die 'Another dxg module lifecycle operation is active.'
}

_dxg_module_loaded() {
    [[ -r $DXG_PROC_MODULES ]] && grep -q '^dxgkrnl ' "$DXG_PROC_MODULES"
}

_dxg_service_active() { systemctl is-active --quiet "$DXG_UNIT"; }
_dxg_service_enabled() { systemctl is-enabled --quiet "$DXG_UNIT"; }

_dxg_fault() {
    local point=$1
    [[ ${DXG_FAIL_AT:-} != "$point" ]] || { printf 'Injected failure at %s\n' "$point" >&2; return 97; }
}

_dxg_atomic_copy() {
    local source=$1 target=$2 mode=$3 dir tmp
    dir=$(dirname "$target")
    mkdir -p "$dir"
    tmp=$(mktemp "${target}.tmp.XXXXXX")
    if ! install -m "$mode" "$source" "$tmp"; then rm -f "$tmp"; return 1; fi
    if ! mv -f "$tmp" "$target"; then rm -f "$tmp"; return 1; fi
}

_dxg_atomic_text() {
    local target=$1 mode=$2 content=$3 dir tmp
    dir=$(dirname "$target")
    mkdir -p "$dir"
    tmp=$(mktemp "${target}.tmp.XXXXXX")
    printf '%s' "$content" > "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$target"
}

_dxg_capture_file() {
    local tx=$1 key=$2 path=$3
    if [[ -e $path || -L $path ]]; then
        printf '%s=present\n' "$key" >> "$tx/files.state"
        cp -a "$path" "$tx/original/$key"
    else
        printf '%s=absent\n' "$key" >> "$tx/files.state"
    fi
}

_dxg_state_value() {
    local file=$1 key=$2
    sed -n "s/^${key}=//p" "$file" | tail -n 1
}

_dxg_new_transaction() {
    local release=$1 operation=$2 state txid tx
    state="$DXG_STATE_ROOT/$release"
    mkdir -p "$state/transactions"
    txid="$(date -u +%Y%m%dT%H%M%S).$$.$RANDOM"
    tx="$state/transactions/$txid"
    (umask 077; mkdir "$tx"; mkdir "$tx/original")
    printf 'format=1\noperation=%s\nrelease=%s\ntxid=%s\n' "$operation" "$release" "$txid" > "$tx/meta"
    if [[ -r $state/current ]]; then
        local previous
        IFS= read -r previous < "$state/current"
        [[ $previous != */* && -n $previous ]] || _dxg_die 'Invalid current transaction marker.'
        printf 'previous=%s\n' "$previous" >> "$tx/meta"
    else
        printf 'previous=\n' >> "$tx/meta"
    fi
    : > "$tx/files.state"
    _dxg_capture_file "$tx" module "$DXG_DEST"
    _dxg_capture_file "$tx" loader "$DXG_LOADER"
    _dxg_capture_file "$tx" unloader "$DXG_UNLOADER"
    _dxg_capture_file "$tx" unit "$DXG_UNIT_FILE"
    if _dxg_service_enabled; then printf 'enabled=yes\n' >> "$tx/service.state"; else printf 'enabled=no\n' >> "$tx/service.state"; fi
    if _dxg_service_active; then printf 'active=yes\n' >> "$tx/service.state"; else printf 'active=no\n' >> "$tx/service.state"; fi
    if _dxg_module_loaded; then printf 'loaded=yes\n' >> "$tx/service.state"; else printf 'loaded=no\n' >> "$tx/service.state"; fi
    printf '%s\n' "$tx"
}

_dxg_seal_transaction() {
    local tx=$1 result=$2
    printf 'result=%s\nfinished=%s\n' "$result" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$tx/meta"
    chmod -R a-w "$tx"
}

_dxg_set_current() {
    local release=$1 txid=$2 marker="$DXG_STATE_ROOT/$release/current" content
    content="$txid"$'\n'
    _dxg_atomic_text "$marker" 0600 "$content"
}

_dxg_clear_current() {
    local release=$1 marker="$DXG_STATE_ROOT/$release/current" tmp
    [[ -e $marker ]] || return 0
    tmp="${marker}.removed.$$"
    mv "$marker" "$tmp"
    rm -f "$tmp"
}

_dxg_restore_previous_marker() {
    local tx=$1 previous
    previous=$(_dxg_state_value "$tx/meta" previous)
    if [[ -n $previous ]]; then _dxg_set_current "$DXG_RELEASE" "$previous"; else _dxg_clear_current "$DXG_RELEASE"; fi
}

_dxg_current_transaction() {
    local release=$1 marker="$DXG_STATE_ROOT/$release/current" txid
    [[ -r $marker ]] || _dxg_die "No installed dxg transaction is recorded for $release."
    IFS= read -r txid < "$marker"
    [[ $txid != */* && -n $txid ]] || _dxg_die 'Invalid current transaction marker.'
    printf '%s/transactions/%s\n' "$DXG_STATE_ROOT/$release" "$txid"
}

_dxg_validate_transaction() {
    local tx=$1 release=$2 tx_release
    [[ -d $tx && -r $tx/meta && -r $tx/files.state && -r $tx/service.state ]] || _dxg_die "Invalid transaction: $tx"
    tx_release=$(_dxg_state_value "$tx/meta" release)
    [[ $tx_release == "$release" ]] || _dxg_die "Transaction targets kernel $tx_release, not $release."
}

_dxg_stop_and_confirm_unloaded() {
    local active=0
    _dxg_service_active && active=1
    if (( active )) || _dxg_module_loaded; then
        systemctl stop "$DXG_UNIT" || return
    fi
    if _dxg_module_loaded && [[ -x $DXG_UNLOADER ]]; then
        "$DXG_UNLOADER" || return
    fi
    if _dxg_module_loaded; then _dxg_die 'dxgkrnl is still loaded; refusing disk replacement.'; fi
    return 0
}

_dxg_restore_file() {
    local tx=$1 key=$2 target=$3 mode=$4 status
    status=$(_dxg_state_value "$tx/files.state" "$key")
    case $status in
        present) _dxg_atomic_copy "$tx/original/$key" "$target" "$mode" ;;
        absent) rm -f "$target" ;;
        *) _dxg_die "Transaction has invalid $key state." ;;
    esac
}

_dxg_restore_snapshot() {
    local tx=$1 enabled active loaded
    _dxg_validate_transaction "$tx" "$DXG_RELEASE"
    _dxg_stop_and_confirm_unloaded
    _dxg_restore_file "$tx" module "$DXG_DEST" 0644
    _dxg_restore_file "$tx" loader "$DXG_LOADER" 0755
    _dxg_restore_file "$tx" unloader "$DXG_UNLOADER" 0755
    _dxg_restore_file "$tx" unit "$DXG_UNIT_FILE" 0644
    systemctl daemon-reload
    enabled=$(_dxg_state_value "$tx/service.state" enabled)
    active=$(_dxg_state_value "$tx/service.state" active)
    loaded=$(_dxg_state_value "$tx/service.state" loaded)
    if [[ $enabled == yes ]]; then
        systemctl enable "$DXG_UNIT"
    elif [[ -e $DXG_UNIT_FILE || -L $DXG_UNIT_FILE ]]; then
        systemctl disable "$DXG_UNIT"
    fi
    if [[ $active == yes ]]; then
        systemctl start "$DXG_UNIT"
    elif [[ $loaded == yes ]]; then
        [[ -x $DXG_LOADER ]] || _dxg_die 'Original module was loaded but its loader cannot be restored.'
        "$DXG_LOADER"
    fi
}

_dxg_err_rollback() {
    local rc=$? line=${1:-unknown}
    trap - ERR
    printf 'Operation failed at line %s (status %s); restoring transaction snapshot.\n' "$line" "$rc" >&2
    if [[ -n ${DXG_TX:-} && -d ${DXG_TX:-} ]]; then
        if _dxg_restore_snapshot "$DXG_TX"; then
            _dxg_seal_transaction "$DXG_TX" rolled-back
        else
            printf 'CRITICAL: automatic rollback failed; inspect %s\n' "$DXG_TX" >&2
        fi
    fi
    exit "$rc"
}
