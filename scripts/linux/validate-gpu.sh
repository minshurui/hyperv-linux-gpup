#!/usr/bin/env bash
set -euo pipefail

fail=0
pass() { printf '[PASS] %s\n' "$*"; }

if [[ -e /dev/dxg ]]; then
    pass '/dev/dxg exists'
else
    echo '[FAIL] /dev/dxg is missing'; fail=1
fi
config="/boot/config-$(uname -r)"
if [[ -r $config ]] && grep -q '^CONFIG_DXGKRNL=y' "$config"; then
    pass 'CONFIG_DXGKRNL=y'
else
    echo "[FAIL] $config lacks CONFIG_DXGKRNL=y"; fail=1
fi

nvidia_smi=${NVIDIA_SMI:-/usr/local/bin/nvidia-smi}
if [[ -x $nvidia_smi ]]; then
    LD_LIBRARY_PATH="/usr/lib/wsl/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$nvidia_smi" \
        --query-gpu=name,driver_version,memory.total --format=csv,noheader
    pass 'nvidia-smi can query the GPU'
else
    echo "[FAIL] nvidia-smi not found: $nvidia_smi"; fail=1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo '[WARN] Host FFmpeg is not installed; codec tests skipped.'
    echo '       For Emby, run validate-emby-compose.sh against its running container.'
    exit "$fail"
fi
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE '(^|[[:space:]])h264_nvenc([[:space:]]|$)'; then
    pass 'FFmpeg exposes h264_nvenc'
else
    echo '[FAIL] FFmpeg has no h264_nvenc'; fail=1
fi
if ffmpeg -hide_banner -decoders 2>/dev/null | grep -qE '(^|[[:space:]])h264_cuvid([[:space:]]|$)'; then
    pass 'FFmpeg exposes h264_cuvid'
else
    echo '[FAIL] FFmpeg has no h264_cuvid'; fail=1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 -t 3 \
    -c:v h264_nvenc -f null -; then
    pass 'NVENC encode smoke test'
else
    echo '[FAIL] NVENC encode smoke test'; fail=1
fi

input="$work/input.mp4"
if ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 -t 3 \
    -c:v h264_nvenc -pix_fmt yuv420p "$input" &&
   ffmpeg -hide_banner -loglevel error -hwaccel cuda -hwaccel_output_format cuda \
    -i "$input" -f null -; then
    pass 'NVDEC decode smoke test'
else
    echo '[FAIL] NVDEC decode smoke test'; fail=1
fi

exit "$fail"
