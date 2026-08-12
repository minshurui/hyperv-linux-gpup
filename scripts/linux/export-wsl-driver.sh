#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 --output /mnt/c/path/wsl-nvidia-driver.tar.gz"
}

output=''
while [[ $# -gt 0 ]]; do
    case $1 in
        --output) output=${2:?}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n $output ]] || { usage >&2; exit 2; }
[[ -d /usr/lib/wsl/lib ]] || { echo '/usr/lib/wsl/lib not found; run this inside an NVIDIA-enabled WSL distribution.' >&2; exit 1; }

mkdir -p "$(dirname "$output")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/usr/lib/wsl"
cp -a /usr/lib/wsl/lib "$tmp/usr/lib/wsl/"

if [[ -d /usr/lib/wsl/drivers ]]; then
    mkdir -p "$tmp/usr/lib/wsl/drivers"
    find /usr/lib/wsl/drivers -mindepth 1 -maxdepth 1 -type d \( \
        -iname 'nv*.inf_amd64_*' -o -iname '*nvidia*' \) -print0 |
    while IFS= read -r -d '' directory; do
        if find "$directory" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' -o -name 'nvidia-smi' \) | grep -q .; then
            cp -a "$directory" "$tmp/usr/lib/wsl/drivers/"
        fi
    done
fi

cat > "$tmp/MANIFEST.txt" <<EOF
Created: $(date -Is)
WSL kernel: $(uname -r)
Source: local /usr/lib/wsl only
Notice: NVIDIA/Microsoft files remain subject to their original licenses.
Do not commit this archive to Git.
EOF

tar -C "$tmp" -czf "$output" MANIFEST.txt usr/lib/wsl
chmod 600 "$output"
printf 'Created %s (%s)\n' "$output" "$(du -h "$output" | awk '{print $1}')"
