#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fakebin="$tmp/bin"
mkdir -p "$fakebin"

cat > "$fakebin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=${DXG_ROOT:?}
state="$root/run/fake-systemctl"
mkdir -p "$state" "$(dirname "$DXG_PROC_MODULES")" "$(dirname "$root/dev/dxg")"
touch "$state/log" "$DXG_PROC_MODULES"
printf '%s\n' "$*" >> "$state/log"
unit=${@: -1}
case ${1:-} in
    is-active) [[ -e $state/active ]] ;;
    is-enabled) [[ -e $state/enabled ]] ;;
    start)
        [[ ${FAKE_SYSTEMCTL_FAIL_START:-0} != 1 ]] || exit 42
        touch "$state/active" "$root/dev/dxg"
        grep -q '^dxgkrnl ' "$DXG_PROC_MODULES" || printf 'dxgkrnl 1 0 - Live 0x0\n' >> "$DXG_PROC_MODULES"
        ;;
    stop)
        [[ ${FAKE_SYSTEMCTL_FAIL_STOP:-0} != 1 ]] || exit 43
        rm -f "$state/active" "$root/dev/dxg"
        sed -i '/^dxgkrnl /d' "$DXG_PROC_MODULES"
        ;;
    enable) touch "$state/enabled" ;;
    disable) rm -f "$state/enabled" ;;
    daemon-reload) : ;;
    *) exit 2 ;;
esac
EOF
cat > "$fakebin/systemd-analyze" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$fakebin/preflight" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fakebin"/*

assert_file() { [[ -f $1 ]] || { echo "missing file: $1" >&2; exit 1; }; }
assert_absent() { [[ ! -e $1 ]] || { echo "unexpected file: $1" >&2; exit 1; }; }
assert_content() { [[ $(cat "$1") == "$2" ]] || { echo "unexpected content in $1" >&2; exit 1; }; }

new_root() {
    ROOT="$tmp/root-$1"
    rm -rf "$ROOT"
    mkdir -p "$ROOT/proc" "$ROOT/dev" "$ROOT/run/fake-systemctl" \
        "$ROOT/usr/local/lib/modules/dxgkrnl/test-kernel" "$ROOT/usr/local/sbin" \
        "$ROOT/etc/systemd/system" "$ROOT/var/lib/hyperv-linux-gpup" "$ROOT/var/lock"
    : > "$ROOT/proc/modules"
}

run_install() {
    local module=$1; shift
    PATH="$fakebin:$PATH" DXG_ROOT="$ROOT" DXG_ALLOW_NON_ROOT=1 DXG_SKIP_DEVICE_WAIT=1 \
        DXG_PROC_MODULES="$ROOT/proc/modules" DXG_FAIL_AT=${DXG_FAIL_AT:-} \
        FAKE_SYSTEMCTL_FAIL_STOP=${FAKE_SYSTEMCTL_FAIL_STOP:-0} \
        FAKE_SYSTEMCTL_FAIL_START=${FAKE_SYSTEMCTL_FAIL_START:-0} \
        "$repo/scripts/linux/install-dxg-module.sh" "$module" --kernel-release test-kernel --apply "$@"
}

# Substitute only uname and preflight dependencies without changing production scripts.
cat > "$fakebin/uname" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == -r ]] && { echo test-kernel; exit 0; }
exec /usr/bin/uname "$@"
EOF
chmod +x "$fakebin/uname"
cp "$repo/scripts/linux/preflight-dxg-module.sh" "$tmp/preflight-real"
cat > "$fakebin/realpath" <<'EOF'
#!/usr/bin/env bash
readlink -f "$1"
EOF
chmod +x "$fakebin/realpath"
# Entry point invokes its sibling preflight. Test a temporary script tree with a no-op preflight.
mkdir -p "$tmp/scripts/linux"
cp "$repo/scripts/linux/install-dxg-module.sh" "$repo/scripts/linux/rollback-dxg-module.sh" \
   "$repo/scripts/linux/uninstall-dxg-module.sh" "$repo/scripts/linux/dxg-module-lifecycle-common.sh" "$tmp/scripts/linux/"
cp "$fakebin/preflight" "$tmp/scripts/linux/preflight-dxg-module.sh"
repo="$tmp"

module="$tmp/new.ko"
printf 'new-module' > "$module"

# Dry-run is side-effect free.
new_root dry
PATH="$fakebin:$PATH" DXG_ROOT="$ROOT" DXG_ALLOW_NON_ROOT=1 "$repo/scripts/linux/install-dxg-module.sh" "$module" --kernel-release test-kernel >/dev/null
assert_absent "$ROOT/usr/local/lib/modules/dxgkrnl/test-kernel/dxgkrnl.ko"

# Fresh install commits immutable state, then explicit uninstall removes managed files.
new_root fresh
run_install "$module" >/dev/null
assert_content "$ROOT/usr/local/lib/modules/dxgkrnl/test-kernel/dxgkrnl.ko" new-module
current=$(cat "$ROOT/var/lib/hyperv-linux-gpup/test-kernel/current")
tx="$ROOT/var/lib/hyperv-linux-gpup/test-kernel/transactions/$current"
[[ $(stat -c '%a' "$tx/meta") != *[2367] ]] || { echo 'transaction metadata has write bits' >&2; exit 1; }
PATH="$fakebin:$PATH" DXG_ROOT="$ROOT" DXG_ALLOW_NON_ROOT=1 DXG_PROC_MODULES="$ROOT/proc/modules" \
    "$repo/scripts/linux/uninstall-dxg-module.sh" --kernel-release test-kernel --apply >/dev/null
assert_absent "$ROOT/usr/local/lib/modules/dxgkrnl/test-kernel/dxgkrnl.ko"
assert_absent "$ROOT/etc/systemd/system/hyperv-linux-gpup-dxg.service"
assert_absent "$ROOT/var/lib/hyperv-linux-gpup/test-kernel/current"

# A second install can transactionally roll back to the first committed install.
new_root rollback
printf first-module > "$tmp/first.ko"
run_install "$tmp/first.ko" >/dev/null
first_tx=$(cat "$ROOT/var/lib/hyperv-linux-gpup/test-kernel/current")
printf second-module > "$tmp/second.ko"
run_install "$tmp/second.ko" >/dev/null
assert_content "$ROOT/usr/local/lib/modules/dxgkrnl/test-kernel/dxgkrnl.ko" second-module
PATH="$fakebin:$PATH" DXG_ROOT="$ROOT" DXG_ALLOW_NON_ROOT=1 DXG_PROC_MODULES="$ROOT/proc/modules" \
    "$repo/scripts/linux/rollback-dxg-module.sh" --kernel-release test-kernel --apply >/dev/null
assert_content "$ROOT/usr/local/lib/modules/dxgkrnl/test-kernel/dxgkrnl.ko" first-module
assert_content "$ROOT/var/lib/hyperv-linux-gpup/test-kernel/current" "$first_tx"

# Failure after replacement restores original bytes and service state.
new_root fault
printf old-module > "$ROOT/usr/local/lib/modules/dxgkrnl/test-kernel/dxgkrnl.ko"
printf old-loader > "$ROOT/usr/local/sbin/hyperv-linux-gpup-dxg-load"
printf old-unloader > "$ROOT/usr/local/sbin/hyperv-linux-gpup-dxg-unload"
printf old-unit > "$ROOT/etc/systemd/system/hyperv-linux-gpup-dxg.service"
chmod +x "$ROOT/usr/local/sbin/hyperv-linux-gpup-dxg-load" "$ROOT/usr/local/sbin/hyperv-linux-gpup-dxg-unload"
touch "$ROOT/run/fake-systemctl/active" "$ROOT/run/fake-systemctl/enabled" "$ROOT/dev/dxg"
printf 'dxgkrnl 1 0 - Live 0x0\n' > "$ROOT/proc/modules"
DXG_FAIL_AT=after-unit
if run_install "$module" >/dev/null 2>&1; then echo 'fault injection unexpectedly succeeded' >&2; exit 1; fi
unset DXG_FAIL_AT
assert_content "$ROOT/usr/local/lib/modules/dxgkrnl/test-kernel/dxgkrnl.ko" old-module
assert_content "$ROOT/usr/local/sbin/hyperv-linux-gpup-dxg-load" old-loader
assert_content "$ROOT/etc/systemd/system/hyperv-linux-gpup-dxg.service" old-unit
assert_file "$ROOT/run/fake-systemctl/active"
assert_file "$ROOT/run/fake-systemctl/enabled"

# A failed stop aborts before any disk replacement and is never ignored.
new_root stop-failure
printf old-module > "$ROOT/usr/local/lib/modules/dxgkrnl/test-kernel/dxgkrnl.ko"
touch "$ROOT/run/fake-systemctl/active" "$ROOT/dev/dxg"
printf 'dxgkrnl 1 0 - Live 0x0\n' > "$ROOT/proc/modules"
FAKE_SYSTEMCTL_FAIL_STOP=1
if run_install "$module" >/dev/null 2>&1; then echo 'stop failure unexpectedly succeeded' >&2; exit 1; fi
unset FAKE_SYSTEMCTL_FAIL_STOP
assert_content "$ROOT/usr/local/lib/modules/dxgkrnl/test-kernel/dxgkrnl.ko" old-module
[[ $(grep -c '^stop ' "$ROOT/run/fake-systemctl/log") -ge 1 ]] || { echo 'stop was not attempted' >&2; exit 1; }

echo 'dxg module lifecycle tests: PASS'
