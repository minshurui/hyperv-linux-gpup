# fnOS Movies hardware transcoding through Hyper-V GPU-P

This document covers the application-level step after `/dev/dxg`, NVIDIA WSL
userspace, standalone NVENC and standalone NVDEC already work. It is not a
replacement for [`FNOS-6.18.md`](FNOS-6.18.md).

## Tested scope

| Component | Tested value |
|---|---|
| fnOS kernel | `6.18.18.c952-trim` |
| fnOS Movies | `mediasrv` 0.8.39 |
| Bundled FFmpeg | 7.1.3 |
| GPU | NVIDIA GeForce RTX 3070 Laptop GPU through GPU-P |
| NVENC API logged by Movies | 12.1 |

The closed-source application version above looked for a physical NVIDIA
DRM/PCI topology. Hyper-V GPU-P instead exposed `/dev/dxg` and a synthetic PCI
function. Standalone FFmpeg success therefore did not make Movies select the
GPU.

## Process-scoped adapter

[`examples/fnos-mediasrv-gpup-compat.c`](../examples/fnos-mediasrv-gpup-compat.c)
is the source of the adapter used for the tested result. It changes only what
the `mediasrv` process sees while performing device discovery:

- the synthetic GPU-P PCI directory is presented under the application-visible
  BDF selected for this exact version;
- the NVIDIA vendor and device identity leaves are returned;
- the exact DRM by-path names used by this version resolve to `/dev/dxg`.

It does **not** create global `/dev/dri` nodes, modify sysfs, interpose CUDA,
NVENC or `dlsym`, fake encoder capability results, or load system-wide. The
source is published, but no compiled `.so`, fnOS binary, Microsoft/NVIDIA
binary, or machine-specific identifier is distributed.

This adapter is application-version-specific and currently supports Linux with
glibc on x86-64, matching the tested fnOS build. It uses glibc symbol versions
and Linux `memfd_create`; it is not a musl or cross-architecture portability
claim. Trace and review a changed `mediasrv` version before reusing it.

## Discover machine-specific values

Find the synthetic PCI function that backs GPU-P:

```bash
for device in /sys/bus/pci/devices/*; do
  printf '%s ' "${device##*/}"
  cat "$device/vendor" "$device/device" 2>/dev/null | tr '\n' ' '
  echo
done
```

Confirm which function maps to `/dev/dxg` with `lspci`, the Hyper-V device IDs,
and a process-scoped trace of the exact application. Do not copy BDFs or a GPU
device ID from another machine. The destination BDF is only an application
view; it must not collide with a real guest device.

## Build

Example placeholders:

```bash
./scripts/linux/build-fnos-mediasrv-compat.sh \
  --source-bdf SYNTHETIC_BDF \
  --visible-bdf APPLICATION_VISIBLE_BDF \
  --nvidia-device-id 0xNNNN \
  --output ./fnos-mediasrv-gpup-compat.so
```

The build fails if the resulting library exports CUDA, NVENC or `dlsym`
interposers.

## Install and roll back

Installation is dry-run by default:

```bash
sudo ./scripts/linux/install-fnos-mediasrv-compat.sh \
  ./fnos-mediasrv-gpup-compat.so
sudo ./scripts/linux/install-fnos-mediasrv-compat.sh \
  ./fnos-mediasrv-gpup-compat.so --apply
```

The input `.so` is executable code loaded into `mediasrv`; build it yourself from
the reviewed source in this repository and do not install an untrusted binary.
The export check is defense in depth, not proof that an arbitrary library is
safe.

The installer:

1. rejects obvious CUDA, NVENC, and `dlsym` interposers;
2. snapshots the previous library and systemd drop-in;
3. installs under `/usr/local/lib/fnos-mediasrv-gpup/`;
4. applies `LD_PRELOAD` only to `mediasrv.service`;
5. restarts the service and confirms the adapter is loaded.

Use the backup path printed by the installer:

```bash
sudo ./scripts/linux/rollback-fnos-mediasrv-compat.sh \
  /var/lib/fnos-mediasrv-gpup/backups/TIMESTAMP
sudo ./scripts/linux/rollback-fnos-mediasrv-compat.sh \
  /var/lib/fnos-mediasrv-gpup/backups/TIMESTAMP --apply
```

## Acceptance: codec support is not enough

Start a real quality transcode from the fnOS Movies UI, then run:

```bash
sudo ./scripts/linux/validate-fnos-movies-gpu.sh
```

Application acceptance requires all of the following:

1. a real `mediasrv` process or child opens `/dev/dxg`;
2. Movies logs `loaded nvenc api`, `gpu in working`, and GPU enablement;
3. `nvidia-smi dmon` shows non-zero encoder and decoder use;
4. new HLS fragments appear in the Movies transcode cache;
5. no new serious kernel, DXG, RAID, or Btrfs warning appears.

On the tested system a real Movies transcode reached 100% encoder and 56%
decoder utilization while writing HLS output. The MD RAID arrays remained
complete and all Btrfs device error counters remained zero.

## Safety boundaries

- Keep the vendor fnOS kernel and its storage stack.
- Never compensate for an experimental kernel failure with `mdadm --force`,
  array recreation, metadata clearing, or `btrfs check --repair`.
- Do not install the adapter globally through `/etc/ld.so.preload`.
- Do not fake CUDA/NVENC success or capabilities. A successful result must come
  from a real Movies transcode.
- Re-test after every fnOS Movies or kernel update; roll back if discovery paths
  or application behavior change.
