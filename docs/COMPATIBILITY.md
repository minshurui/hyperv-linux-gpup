# Compatibility and provenance

## Supported source and target

The external-module workflow is deliberately narrow and fail closed.

| Item | Exact tested value |
|---|---|
| Microsoft repository | `https://github.com/microsoft/WSL2-Linux-Kernel.git` |
| Source tag | `linux-msft-wsl-6.6.87.2` |
| Source commit | `427645e3db3a8896714f22a3d3fe0c3f7b317ad4` |
| Source payload | `drivers/hv/dxgkrnl` plus `include/uapi/misc/d3dkmthk.h` |
| Target kernel | `6.18.18.c952-trim` |
| Build form | external `dxgkrnl.ko` |

No compatibility is claimed for another Microsoft tag or commit, a locally
modified source file, or another target kernel. `build-dxg-module-6.18.sh`
accepts a `6.18.*` release only to support the tested build procedure; that
input check is not a statement that every 6.18 kernel ABI works.

## Reproducible source verification

`patches/dxgkrnl/6.6-to-6.18/provenance.json` is the machine-readable source
of truth. It records the upstream identity, SHA-256 of every copied upstream
file, ordered patch list, SHA-256 of every patch and the tested target.

Prepare a disposable tree with:

```bash
./scripts/linux/prepare-dxg-source.sh \
  --source /usr/src/WSL2-Linux-Kernel-6.6.87.2 \
  --output ./dxg-prepared
```

Preparation performs these checks before publishing output:

1. every required upstream file exists and matches its recorded SHA-256;
2. when the source is a Git checkout, `HEAD` equals the recorded commit;
3. `series` and each patch match the manifest and retain their exact order;
4. all five patches apply with zero fuzz;
5. the in-tree Makefile anchors each match exactly once.

Any mismatch aborts. Existing output is never deleted or overwritten, and a
failed run leaves no partial output directory. This behavior intentionally
requires reviewing and recording a new source snapshot rather than silently
adapting unknown code.

## Compatibility patch series

The ordered series under `patches/dxgkrnl/6.6-to-6.18/` contains one semantic
change per patch:

1. include `<linux/vmalloc.h>` explicitly;
2. use the Linux 6.18 one-argument `eventfd_signal()` API;
3. provide the Microsoft GPU-P GLOBAL and VGPU VMBus GUID initializers when absent;
4. adapt `__dma_fence_is_later()` and remove obsolete fence debug callbacks;
5. replace internal `__get_task_comm()` with public `get_task_comm()`.

The patches are source compatibility adaptations, not evidence of runtime
compatibility by themselves. Build success also does not prove exact symbol
ABI, module loading, `/dev/dxg`, GPU userspace or application transcoding.
Follow the preflight and acceptance ladder in [FNOS-6.18.md](FNOS-6.18.md).

## Updating the snapshot

Treat a source or patch update as a new reviewed compatibility snapshot:

1. identify and record the exact upstream tag and full commit;
2. regenerate source hashes from a clean checkout;
3. refresh patches without fuzz and keep one concern per patch;
4. regenerate patch and `series` hashes in `provenance.json`;
5. run fixture tests, build against exact target headers and `Module.symvers`,
   then repeat runtime acceptance before documenting support.

Never weaken or bypass the hashes to make a newer source tree pass.
