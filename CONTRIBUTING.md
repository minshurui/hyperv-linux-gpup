# Contributing

1. Open an issue before changing the supported platform matrix.
2. Do not commit Microsoft/NVIDIA binaries, compiled kernels, driver archives,
   VM images, credentials, or machine-specific state.
3. Keep mutating commands behind an explicit `-Action Apply` or `--apply`.
4. Preserve a rollback path and do not remove distribution kernels.
5. Run `tests/lint.sh` before opening a pull request.
6. Document hardware, Windows build, VM generation and guest distribution for
   behavior changes, but redact serial numbers and credentials.

Scripts must be idempotent where practical and fail closed when the host has
multiple partitionable GPUs or unsupported boot/security settings.
