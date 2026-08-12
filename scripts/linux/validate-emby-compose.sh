#!/usr/bin/env bash
set -euo pipefail

compose_file=${1:-docker-compose.yml}
service=${2:-emby}
ffmpeg_path=${3:-/bin/ffmpeg}
[[ -f $compose_file ]] || { echo "Compose file not found: $compose_file" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo 'docker is required.' >&2; exit 1; }

config=$(docker compose -f "$compose_file" config)
grep -q '/dev/dxg' <<<"$config" || { echo "[FAIL] $service does not map /dev/dxg"; exit 1; }
grep -q '/usr/lib/wsl/lib' <<<"$config" || { echo '[FAIL] WSL user-mode library mount is missing'; exit 1; }
grep -q '/usr/lib/wsl/drivers' <<<"$config" || { echo '[FAIL] WSL driver-store mount is missing'; exit 1; }
container=$(docker compose -f "$compose_file" ps -q "$service")
[[ -n $container ]] || { echo "[FAIL] service is not running: $service"; exit 1; }
docker exec "$container" test -e /dev/dxg
docker exec "$container" sh -c 'test -d /usr/lib/wsl/lib'
docker exec "$container" sh -c 'test -d /usr/lib/wsl/drivers'
echo "[PASS] $service has dxg device and WSL driver mounts"

docker exec "$container" sh -c '
    set -e
    ffmpeg=$1
    test -x "$ffmpeg"
    output=/tmp/hyperv-linux-gpup-smoke.mp4
    trap '\''rm -f "$output"'\'' EXIT
    "$ffmpeg" -hide_banner -loglevel error \
        -f lavfi -i testsrc2=size=640x360:rate=15 -t 1 \
        -c:v h264_nvenc -y "$output"
    "$ffmpeg" -hide_banner -loglevel error \
        -hwaccel cuda -hwaccel_output_format cuda \
        -i "$output" -f null -
' -- "$ffmpeg_path"
echo "[PASS] $service completed an NVENC to NVDEC smoke test"
