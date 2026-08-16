#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-fnos-mediasrv-compat.sh --source-bdf BDF --visible-bdf BDF \
       --nvidia-device-id HEX [--output FILE]

Build the process-scoped fnOS Movies mediasrv GPU-P discovery adapter.
BDF examples are machine-specific; discover them on the target guest.
EOF
}

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source_bdf=
visible_bdf=
device_id=
output="$PWD/fnos-mediasrv-gpup-compat.so"
while (($#)); do
    case "$1" in
        --source-bdf) source_bdf=${2:?}; shift 2 ;;
        --visible-bdf) visible_bdf=${2:?}; shift 2 ;;
        --nvidia-device-id) device_id=${2:?}; shift 2 ;;
        --output) output=${2:?}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 64 ;;
    esac
done

bdf_re='^[[:xdigit:]]{4,8}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$'
[[ $source_bdf =~ $bdf_re ]] || { echo 'invalid --source-bdf' >&2; exit 64; }
[[ $visible_bdf =~ $bdf_re ]] || { echo 'invalid --visible-bdf' >&2; exit 64; }
((${#visible_bdf} <= ${#source_bdf})) || { echo '--visible-bdf must not be longer than --source-bdf' >&2; exit 64; }
[[ $device_id =~ ^0x[[:xdigit:]]{4}$ ]] || { echo 'invalid --nvidia-device-id' >&2; exit 64; }
command -v gcc >/dev/null
command -v readelf >/dev/null
command -v nm >/dev/null
mkdir -p "$(dirname "$output")"
temporary="$output.tmp.$$"
trap 'rm -f "$temporary"' EXIT

gcc -shared -fPIC -O2 -Wall -Wextra -Werror \
    -DSRC_BDF="\"$source_bdf\"" \
    -DDST_BDF="\"$visible_bdf\"" \
    -DNVIDIA_DEVICE_ID="\"$device_id\\n\"" \
    -o "$temporary" "$ROOT/examples/fnos-mediasrv-gpup-compat.c" -ldl
readelf -h "$temporary" >/dev/null
nm -D "$temporary" | grep -Eq ' (access|open|open64|readdir|readdir64|realpath)$'
if nm -D "$temporary" | grep -Eq ' (cu[A-Za-z0-9_]*|NvEncode[A-Za-z0-9_]*|dlsym)$'; then
    echo 'refusing CUDA, NVENC, or dlsym interposer' >&2
    exit 1
fi
chmod 0555 "$temporary"
mv -f "$temporary" "$output"
trap - EXIT
sha256sum "$output"
