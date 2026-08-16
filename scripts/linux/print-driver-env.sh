#!/usr/bin/env bash
set -euo pipefail

base=/usr/lib/wsl/lib
drivers=/usr/lib/wsl/drivers
paths=()
[[ -d $base ]] && paths+=("$base")
if [[ -d $drivers ]]; then
    while IFS= read -r -d '' directory; do
        paths+=("$directory")
    done < <(find "$drivers" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
fi
((${#paths[@]} > 0)) || { echo 'No WSL NVIDIA user-mode library directory found.' >&2; exit 1; }
printf 'LD_LIBRARY_PATH=%s\n' "$(IFS=:; echo "${paths[*]}")"
