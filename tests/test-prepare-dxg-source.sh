#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=${DXG_FIXTURE_SOURCE:-"$root/../dxg-fixture-upstream"}
prepare="$root/scripts/linux/prepare-dxg-source.sh"
[[ -d $fixture ]] || { echo "SKIP: fixture not found: $fixture"; exit 0; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-prepare-dxg.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

output="$tmp/prepared"
"$prepare" --source "$fixture" --output "$output"
module="$output/drivers/hv/dxgkrnl"

grep -Fqx 'obj-m += dxgkrnl.o' "$module/Makefile"
# The Make variable must remain literal.
# shellcheck disable=SC2016
grep -Fqx 'ccflags-y += -I$(src)/include' "$module/Makefile"
grep -Fq '#include <linux/vmalloc.h>' "$module/dxgkrnl.h"
grep -Fq 'eventfd_signal(event->cpu_event);' "$module/dxgmodule.c"
grep -Fq '#define HV_GPUP_DXGK_GLOBAL_GUID' "$module/dxgmodule.c"
grep -Fq 'return __dma_fence_is_later(fence, syncpoint->fence_value,' "$module/dxgsyncfile.c"
if grep -Fq '.fence_value_str =' "$module/dxgsyncfile.c"; then exit 1; fi
if grep -Fq '.timeline_value_str =' "$module/dxgsyncfile.c"; then exit 1; fi
grep -Fq 'get_task_comm(s, current);' "$module/dxgvmbus.c"
[[ -f $module/include/uapi/misc/d3dkmthk.h ]]

if "$prepare" --source "$fixture" --output "$output" >"$tmp/existing.log" 2>&1; then
    echo 'FAIL: existing output was overwritten' >&2
    exit 1
fi
grep -Fq 'Refusing to overwrite existing output' "$tmp/existing.log"

cp -a "$fixture" "$tmp/mutated"
printf '\n/* changed fixture */\n' >> "$tmp/mutated/drivers/hv/dxgkrnl/dxgmodule.c"
if "$prepare" --source "$tmp/mutated" --output "$tmp/rejected" >"$tmp/hash.log" 2>&1; then
    echo 'FAIL: modified upstream source was accepted' >&2
    exit 1
fi
grep -Fq 'source hash mismatch: drivers/hv/dxgkrnl/dxgmodule.c' "$tmp/hash.log"
[[ ! -e $tmp/rejected ]]

mkdir -p "$tmp/repo/scripts/linux" "$tmp/repo/patches/dxgkrnl"
cp "$prepare" "$tmp/repo/scripts/linux/"
cp -a "$root/patches/dxgkrnl/6.6-to-6.18" "$tmp/repo/patches/dxgkrnl/"
printf '\n' >> "$tmp/repo/patches/dxgkrnl/6.6-to-6.18/0002-dxgkrnl-adapt-eventfd-signal.patch"
if "$tmp/repo/scripts/linux/prepare-dxg-source.sh" --source "$fixture" \
    --output "$tmp/tampered" >"$tmp/patch-hash.log" 2>&1; then
    echo 'FAIL: modified patch series was accepted' >&2
    exit 1
fi
grep -Fq 'patch hash mismatch: 0002-dxgkrnl-adapt-eventfd-signal.patch' "$tmp/patch-hash.log"
[[ ! -e $tmp/tampered ]]

printf 'PASS: exact fixture patched; source, patch, and overwrite failures rejected.\n'
