#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
validator="$ROOT/scripts/linux/validate-wsl-driver-archive.py"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 "$ROOT/tests/wsl-driver-archive-fixtures.py" "$tmp/fixtures"
python3 "$validator" "$tmp/fixtures/good.tar.gz" --extract "$tmp/extracted"
[[ $(cat "$tmp/extracted/usr/lib/wsl/lib/libcuda.so.1") == fixture-library ]]
[[ $(readlink "$tmp/extracted/usr/lib/wsl/lib/libcuda.so") == libcuda.so.1 ]]
[[ -x $tmp/extracted/usr/lib/wsl/lib/nvidia-smi ]]

malicious=(
    absolute.tar.gz
    bad-hash.tar.gz
    duplicate.tar.gz
    escaping-link.tar.gz
    outside-allowlist.tar.gz
    special-member.tar.gz
    traversal.tar.gz
    unlisted-member.tar.gz
)
for fixture in "${malicious[@]}"; do
    if python3 "$validator" "$tmp/fixtures/$fixture" >"$tmp/$fixture.out" 2>&1; then
        echo "FAIL: malicious fixture accepted: $fixture" >&2
        exit 1
    fi
done

if python3 "$validator" "$tmp/fixtures/good.tar.gz" --max-members 2 >"$tmp/member-limit.out" 2>&1; then
    echo 'FAIL: member-count limit was not enforced' >&2
    exit 1
fi
if python3 "$validator" "$tmp/fixtures/good.tar.gz" --max-file-size 4 >"$tmp/file-limit.out" 2>&1; then
    echo 'FAIL: per-file size limit was not enforced' >&2
    exit 1
fi
if python3 "$validator" "$tmp/fixtures/good.tar.gz" --max-total-size 20 >"$tmp/total-limit.out" 2>&1; then
    echo 'FAIL: total size limit was not enforced' >&2
    exit 1
fi

echo "PASS: good fixture accepted; ${#malicious[@]} malicious fixtures and archive limits rejected."
