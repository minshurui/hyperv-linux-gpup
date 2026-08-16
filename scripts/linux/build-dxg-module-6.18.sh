#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-dxg-module-6.18.sh --source WSL_KERNEL_TREE [--kernel-release RELEASE]
       [--kernel-build DIR] [--work DIR] [--output DIR] [--jobs N]

Build drivers/hv/dxgkrnl from a Microsoft WSL 6.6 source tree as an external
module for an already prepared Linux 6.18 kernel. The source tree is copied;
the upstream checkout and running system are not modified. No module is loaded
or installed by this script.
EOF
}
source_dir=''
release=$(uname -r)
kdir=''
work=''
output=''
jobs=$(nproc)
while [[ $# -gt 0 ]]; do
    case $1 in
        --source) source_dir=${2:?}; shift 2 ;;
        --kernel-release) release=${2:?}; shift 2 ;;
        --kernel-build) kdir=${2:?}; shift 2 ;;
        --work) work=${2:?}; shift 2 ;;
        --output) output=${2:?}; shift 2 ;;
        --jobs) jobs=${2:?}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n $source_dir ]] || { usage >&2; exit 2; }
[[ $release == 6.18.* ]] || { echo "Refusing untested target kernel: $release" >&2; exit 2; }
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo '--jobs must be positive.' >&2; exit 2; }
[[ -d $source_dir/drivers/hv/dxgkrnl ]] || { echo 'WSL dxgkrnl source not found.' >&2; exit 1; }
[[ -f $source_dir/include/uapi/misc/d3dkmthk.h ]] || { echo 'd3dkmthk.h not found.' >&2; exit 1; }
: "${kdir:=/usr/src/linux-headers-$release}"
[[ -f $kdir/Makefile && -f $kdir/Module.symvers ]] || {
    echo "Prepared kernel build tree with Module.symvers not found: $kdir" >&2; exit 1;
}
: "${work:=$PWD/dxg-module-$release}"
: "${output:=$PWD/dxg-module-artifacts-$release}"
rm -rf "$work"
mkdir -p "$work/include/uapi/misc" "$output"
cp -a "$source_dir/drivers/hv/dxgkrnl/." "$work/"
cp -a "$source_dir/include/uapi/misc/d3dkmthk.h" "$work/include/uapi/misc/"

# Convert the in-tree object list to one external module without copying other
# WSL kernel subsystems.
awk '
/^dxgkrnl-y[[:space:]]*:?=/ { sub(/^dxgkrnl-y[[:space:]]*:?=/, "dxgkrnl-objs :="); print; next }
/^obj-\$\(CONFIG_DXGKRNL\)[[:space:]]*\+=/ { print "obj-m += dxgkrnl.o"; next }
{ print }
' "$work/Makefile" > "$work/Makefile.external"
mv "$work/Makefile.external" "$work/Makefile"
printf '\nccflags-y += -I$(src)/include\n' >> "$work/Makefile"

grep -q '^#include <linux/vmalloc.h>' "$work/dxgkrnl.h" ||
    sed -i '1i#include <linux/vmalloc.h>' "$work/dxgkrnl.h"
sed -i 's/eventfd_signal(event->cpu_event, 1);/eventfd_signal(event->cpu_event);/' "$work/dxgmodule.c"
sed -i 's/__get_task_comm(s, WIN_MAX_PATH, current);/get_task_comm(s, current);/' "$work/dxgvmbus.c"
python3 - "$work" <<'PY'
from pathlib import Path
import sys
w = Path(sys.argv[1])
p = w / "dxgmodule.c"
s = p.read_text()
anchor = '#include "dxgsyncfile.h"\n'
compat = '''#include "dxgsyncfile.h"

#ifndef HV_GPUP_DXGK_GLOBAL_GUID
#define HV_GPUP_DXGK_GLOBAL_GUID \\
    .guid = GUID_INIT(0xdde9cbc0, 0x5060, 0x4436, 0x94, 0x48, \\
                      0xea, 0x12, 0x54, 0xa5, 0xd1, 0x77)
#endif
#ifndef HV_GPUP_DXGK_VGPU_GUID
#define HV_GPUP_DXGK_VGPU_GUID \\
    .guid = GUID_INIT(0x6e382d18, 0x3336, 0x4f4b, 0xac, 0xc4, \\
                      0x2b, 0x77, 0x03, 0xd4, 0xdf, 0x4a)
#endif
'''
if 'ifndef HV_GPUP_DXGK_GLOBAL_GUID' not in s:
    if anchor not in s: raise SystemExit('dxgmodule include anchor not found')
    s = s.replace(anchor, compat, 1)
p.write_text(s)
p = w / "dxgsyncfile.c"
s = p.read_text()
s = s.replace('return __dma_fence_is_later(syncpoint->fence_value, fence->seqno,\n\t\t\t\t    fence->ops);',
              'return __dma_fence_is_later(fence, syncpoint->fence_value,\n\t\t\t\t    fence->seqno);')
s = s.replace('\n\t.fence_value_str = dxgdmafence_value_str,', '')
s = s.replace('\n\t.timeline_value_str = dxgdmafence_timeline_value_str,', '')
p.write_text(s)
PY

log="$output/build.log"
make -C "$kdir" M="$work" clean
timeout 1800 make -C "$kdir" M="$work" -j"$jobs" modules 2>&1 | tee "$log"
ko="$work/dxgkrnl.ko"
[[ -f $ko ]] || { echo 'dxgkrnl.ko was not produced.' >&2; exit 1; }
cp -f "$ko" "$output/dxgkrnl.ko"
modinfo "$ko" > "$output/modinfo.txt"
sha256sum "$output/dxgkrnl.ko" > "$output/SHA256SUMS"
printf 'Built %s for %s; artifacts: %s\n' "$ko" "$release" "$output"
