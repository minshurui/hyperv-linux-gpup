#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$ROOT/scripts/linux/build-fnos-mediasrv-compat.sh" \
    --source-bdf a17a:00:00.0 \
    --visible-bdf 0000:01:00.0 \
    --nvidia-device-id 0x249d \
    --output "$tmp/compat.so"
[[ -s $tmp/compat.so ]]
nm -D "$tmp/compat.so" | grep -Eq ' (access|open|open64|readdir|readdir64|realpath)$'
if nm -D "$tmp/compat.so" | grep -Eq ' (cu[A-Za-z0-9_]*|NvEncode[A-Za-z0-9_]*|dlsym)$'; then
    echo 'forbidden interposer exported' >&2
    exit 1
fi
if "$ROOT/scripts/linux/build-fnos-mediasrv-compat.sh" \
    --source-bdf invalid --visible-bdf 0000:01:00.0 \
    --nvidia-device-id 0x249d --output "$tmp/bad.so"; then
    echo 'invalid BDF unexpectedly accepted' >&2
    exit 1
fi
if "$ROOT/scripts/linux/build-fnos-mediasrv-compat.sh" \
    --source-bdf 0000:01:00.0 --visible-bdf a17aabcd:00:00.0 \
    --nvidia-device-id 0x249d --output "$tmp/long.so"; then
    echo 'longer visible BDF unexpectedly accepted' >&2
    exit 1
fi
echo 'PASS: fnOS mediasrv adapter builds with a narrow export boundary'
