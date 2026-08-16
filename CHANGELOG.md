# Changelog

## Unreleased

- Documented the tested fnOS 6.18 external-module path and its difference from the whole WSL-kernel experiment.
- Added a parameterized out-of-tree `dxgkrnl` 6.6-to-6.18 compatibility builder.
- Added exact target `Module.symvers`/vermagic preflight and kernel-scoped dry-run installation and rollback.
- Updated GPU validation for loaded external modules, WSL DriverStore paths, and bounded command timeouts.

## 0.1.0 - 2026-08-12

- Initial open-source method package for Hyper-V Linux GPU-P with `dxgkrnl`.
- Added host preflight and idempotent GPU-P/MMIO configuration with rollback state.
- Added local WSL NVIDIA userspace export/install workflow without redistributing drivers.
- Added local kernel build/install workflow without redistributing kernel binaries.
- Added DXG, NVDEC, NVENC and Emby validation scripts.
- Added boot diagnostics, CI checks and secret/artifact exclusions.
