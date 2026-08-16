# fnOS 6.18 external `dxgkrnl` port

## Tested result

This path keeps the vendor fnOS kernel and storage stack intact. It was tested with:

| Component | Tested value |
|---|---|
| Guest | fnOS, Hyper-V Generation 1 |
| Target kernel | `6.18.18.c952-trim` |
| dxg source | `linux-msft-wsl-6.6.87.2` at `427645e3db3a8896714f22a3d3fe0c3f7b317ad4` |
| Module mode | external `dxgkrnl.ko`, version 2.0.3 |
| GPU | NVIDIA GeForce RTX 3070 Laptop GPU through GPU-P |
| NVIDIA userspace | WSL libraries, driver 537.58 |
| Media userspace | fnOS mediasrv FFmpeg 7.1.3 |

The original experiment booted a complete WSL-derived `6.6.87.2-dxg-hyperv` kernel. `/dev/dxg` appeared, but fnOS MD arrays did not auto-assemble. The successful design instead built only `dxgkrnl` against the exact fnOS 6.18 headers and `Module.symvers`. This preserved the vendor kernel, RAID assembly, and Btrfs behavior.

This is a narrow compatibility result, not a claim that arbitrary WSL and 6.18 revisions are ABI compatible.

## Compatibility changes

The reusable builder applies six source adaptations to a disposable copy:

1. Include `<linux/vmalloc.h>` explicitly for `vfree`.
2. Use the current one-argument `eventfd_signal()` call.
3. Define the Microsoft GPU-P GLOBAL and VGPU VMBus GUIDs when the target headers do not provide them.
4. Adapt `__dma_fence_is_later()` and omit removed fence debug callbacks.
5. Replace internal `__get_task_comm()` use with `get_task_comm()`.
6. Hold the mmap write lock while mutating a VMA and calling `io_remap_pfn_range()` in `dxg_map_iospace()`.

The six changes are maintained as an ordered patch series. Source hashes, patch hashes, zero-fuzz application, and exact Makefile anchors are verified before build; a changed source fails preparation rather than being treated as compatible. See [COMPATIBILITY.md](COMPATIBILITY.md).

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
sudo ./scripts/linux/rollback-dxg-module.sh --apply
sudo ./scripts/linux/uninstall-dxg-module.sh
sudo ./scripts/linux/uninstall-dxg-module.sh --apply
```

The module is kernel-scoped. Lifecycle operations are dry-run by default, share one lock, preserve immutable transaction snapshots, use same-filesystem atomic replacements, and automatically restore the captured module/loader/unit/service state on error. Stop failures are fatal, and the module must be confirmed unloaded before disk replacement. See [`DXG-MODULE-LIFECYCLE.md`](DXG-MODULE-LIFECYCLE.md) for rollback selection, safe uninstall, and fault-injection tests. Never force-unload the module.

## Acceptance ladder

Treat each step as separate evidence:

1. Vendor kernel still runs and storage arrays are healthy.
2. `/dev/dxg` exists and `dxgkrnl` is loaded.
3. `nvidia-smi` identifies the expected GPU through WSL userspace.
4. FFmpeg performs real NVENC and NVDEC jobs.
5. The target media application launches its own hardware transcoder and GPU utilization is observed.
6. A controlled cold boot preserves the vendor kernel, storage, service, and application state.

Steps 1–4 do not prove step 5. In particular, codec advertisement and standalone FFmpeg success are not media-application acceptance.

### Tested fnOS Movies result

On the tested system, fnOS Movies `mediasrv` 0.8.39 initially triggered
`rwsem_assert_held_write_nolockdep()` from `remap_pfn_range_internal()` while
creating paging queues and mappings. Patch 6 changed only the stale WSL 6.6
mmap read lock to the write lock required by Linux 6.18. After rebuilding and
transactionally switching the module:

- standalone H.264 NVENC and CUVID/NVDEC completed with no new kernel warning;
- the Movies API detected exactly one `NVIDIA GeForce RTX 3070 Laptop GPU`;
- `mediasrv` logged `loaded nvenc api version 12.1`, `gpu in working`, and
  `gpu enable: true, selected sequence: 1`;
- a real Movies quality transcode opened `/dev/dxg` from a `mediasrv` child,
  wrote new HLS segments under the configured transcode cache, and reached
  100% encoder and 56% decoder utilization in `nvidia-smi dmon`;
- MD RAID remained complete and Btrfs device error counters remained zero.

The fnOS application still needed a process-scoped device-discovery adapter
because GPU-P exposes `/dev/dxg` and a synthetic PCI function rather than the
physical NVIDIA DRM/PCI topology expected by this closed-source version. That
adapter renamed only the process-visible PCI directory identity, returned the
NVIDIA vendor/device leaves, and resolved the exact DRM by-path names to
`/dev/dxg`. It did not interpose CUDA, NVENC, `dlsym`, or capability return
values, and it was never installed system-wide. This application-specific
adapter is not part of the generic kernel module package. Its auditable source,
parameterized build, process-scoped install/rollback, and real Movies acceptance
procedure are published separately in [FNOS-MOVIES.md](FNOS-MOVIES.md).

## fnOS safety notes

- Keep the vendor kernel as default and recovery kernel.
- Do not use `mdadm --force`, recreate arrays, zero metadata, or run destructive Btrfs repair to compensate for a test-kernel boot failure.
- Do not edit a media-server settings file behind the application if it rewrites that file; use its authenticated settings API or GUI.
- Do not install DKMS unless the vendor supplies a stable header lifecycle. Re-run build and exact-ABI preflight after every fnOS kernel update.
- An unsigned external module taints the kernel. Secure Boot/module-signing policy must be handled explicitly on systems that enforce it.
