#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

mapfile -t scripts < <(find scripts tests -type f -name '*.sh' -print | sort)
for script in "${scripts[@]}"; do
    bash -n "$script"
done

mapfile -t python_scripts < <(find scripts tests -type f -name '*.py' -print | sort)
if ((${#python_scripts[@]})); then
    python3 -m py_compile "${python_scripts[@]}"
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "${scripts[@]}"
else
    echo 'WARN: shellcheck is not installed; syntax checks only.' >&2
fi

# Keep obvious secrets and private keys out of commits. The fragmented regexes
# avoid teaching generic scanners to flag this test file itself.
patterns=(
    'BEGIN (OPENSSH|RSA) PRIVATE KEY'
    '[A-Za-z_]*(TOKEN|PASSWORD|SECRET|COOKIE)[A-Za-z_]*=[A-Za-z0-9_+/=-]{16,}'
)
for pattern in "${patterns[@]}"; do
    if grep -RInE --exclude-dir=.git --exclude='lint.sh' "$pattern" .; then
        echo "Potential secret matched: $pattern" >&2
        exit 1
    fi
done

bash tests/test-wsl-driver-archive.sh
bash tests/test-prepare-dxg-source.sh
bash tests/test-fnos-mediasrv-compat.sh

echo "PASS: ${#scripts[@]} shell scripts and ${#python_scripts[@]} Python scripts checked; no forbidden secret pattern found."
