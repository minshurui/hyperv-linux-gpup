# fnOS 6.18 external `dxgkrnl` port

## Tested result

This path keeps the vendor fnOS kernel and storage stack intact. It was tested with:

| Component | Tested value |
|---|---|
| Guest | fnOS, Hyper-V Generation 1 |
| Target kernel | `6.18.18.c952-trim` |
| dxg source family | Microsoft WSL2 kernel 6.6 `drivers/hv/dxgkrnl` |
| Module mode | external `dxgkrnl.ko`, version 2.0.3 |
| GPU | NVIDIA GeForce RTX 3070 Laptop GPU through GPU-P |
| NVIDIA userspace | WSL libraries, driver 537.58 |
| Media userspace | fnOS mediasrv FFmpeg 7.1.3 |

The original experiment booted a complete WSL-derived `6.6.87.2-dxg-hyperv` kernel. `/dev/dxg` appeared, but fnOS MD arrays did not auto-assemble. The successful design instead built only `dxgkrnl` against the exact fnOS 6.18 headers and `Module.symvers`. This preserved the vendor kernel, RAID assembly, and Btrfs behavior.

This is a narrow compatibility result, not a claim that arbitrary WSL and 6.18 revisions are ABI compatible.

## Compatibility changes

The reusable builder applies five source adaptations to a disposable copy:

1. Include `<linux/vmalloc.h>` explicitly for `vfree`.
2. Use the current one-argument `eventfd_signal()` call.
3. Define the Microsoft GPU-P GLOBAL and VGPU VMBus GUIDs when the target headers do not provide them.
4. Adapt `__dma_fence_is_later()` and omit removed fence debug callbacks.
5. Replace internal `__get_task_comm()` use with `get_task_comm()`.

Every replacement is intentionally anchor-based. A changed upstream source should fail at compilation or preflight rather than be treated as compatible.

## Build without replacing the fnOS kernel

Prepare the exact headers for the running vendor kernel, including its `Module.symvers`. Then use a locally obtained Microsoft WSL source tree:

```bash
sudo ./scripts/linux/build-dxg-module-6.18.sh \
  --source /usr/src/WSL2-Linux-Kernel-6.6.87.2 \
  --kernel-release "$(uname -r)" \
  --kernel-build "/usr/src/linux-headers-$(uname -r)" \
  --output ./dxg-module-artifacts
```

The script does not download source, load a module, edit boot files, or install anything.

## Exact ABI preflight

```bash
sudo ./scripts/linux/preflight-dxg-module.sh \
  ./dxg-module-artifacts/dxgkrnl.ko
```

Do not substitute `/proc/kallsyms` for `Module.symvers`: a symbol visible in kallsyms is not necessarily exported to modules. Vermagic and every undefined reference must match the exact target build.

## Dry-run installation and rollback

```bash
sudo ./scripts/linux/install-dxg-module.sh ./dxg-module-artifacts/dxgkrnl.ko
sudo ./scripts/linux/install-dxg-module.sh ./dxg-module-artifacts/dxgkrnl.ko --apply
sudo ./scripts/linux/rollback-dxg-module.sh
sudo ./scripts/linux/rollback-dxg-module.sh --backup /var/lib/hyperv-linux-gpup/$(uname -r)/backups/<file> --apply
```

The module is kernel-scoped. Installation is dry-run by default, preserves previous modules, uses an operation lock, and installs an idempotent service. Rollback refuses to unload while `/dev/dxg` has open users. Never force-unload the module.

## Acceptance ladder

Treat each step as separate evidence:

1. Vendor kernel still runs and storage arrays are healthy.
2. `/dev/dxg` exists and `dxgkrnl` is loaded.
3. `nvidia-smi` identifies the expected GPU through WSL userspace.
4. FFmpeg performs real NVENC and NVDEC jobs.
5. The target media application launches its own hardware transcoder and GPU utilization is observed.
6. A controlled cold boot preserves the vendor kernel, storage, service, and application state.

Steps 1–4 do not prove step 5. In particular, codec advertisement and standalone FFmpeg success are not media-application acceptance.

## fnOS safety notes

- Keep the vendor kernel as default and recovery kernel.
- Do not use `mdadm --force`, recreate arrays, zero metadata, or run destructive Btrfs repair to compensate for a test-kernel boot failure.
- Do not edit a media-server settings file behind the application if it rewrites that file; use its authenticated settings API or GUI.
- Do not install DKMS unless the vendor supplies a stable header lifecycle. Re-run build and exact-ABI preflight after every fnOS kernel update.
- An unsigned external module taints the kernel. Secure Boot/module-signing policy must be handled explicitly on systems that enforce it.
