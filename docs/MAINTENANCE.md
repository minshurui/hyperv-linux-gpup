# Maintenance

## After a Windows NVIDIA driver update

1. Confirm `nvidia-smi` still works in WSL.
2. Run `export-wsl-driver.sh` again in WSL.
3. Validate the archive in the VM without `--apply`.
4. Install with `--apply`; the old `/usr/lib/wsl` is retained with a timestamp.
5. Run `validate-gpu.sh` and `validate-emby-compose.sh`.

Do not keep a DriverStore directory hash in a reusable script.

## Updating the custom kernel

The custom kernel does not receive Debian kernel security updates automatically.
Periodically select a newer Microsoft WSL2 kernel tag that still contains
`drivers/hv/dxgkrnl`, then:

1. Re-run `guest-preflight.sh`.
2. Build from the current distribution kernel config.
3. Install the new packages without removing existing kernels.
4. Use a one-time GRUB boot.
5. Validate network, storage, `/dev/dxg`, NVENC/NVDEC and services.
6. Only then set the new kernel as the saved default.

Keep at least one known-good distribution kernel and one previously verified
DXG kernel until the new version has survived a full reboot.

## Backups retained by the scripts

- Windows GPU-P/MMIO state: `state/<VM>-gpup.json`
- Previous WSL user-mode library tree: `/usr/lib/wsl.before-<timestamp>`
- Failed new library tree: `/usr/lib/wsl.failed-<timestamp>` (when validation triggers rollback)
- Boot diagnostics: caller-selected `state/` directory

These locations may contain machine inventory or proprietary binaries and are
excluded from Git.

## Periodic verification

```bash
sudo ./scripts/linux/guest-preflight.sh
sudo ./scripts/linux/validate-gpu.sh
sudo ./scripts/linux/validate-emby-compose.sh /path/docker-compose.yml emby /bin/ffmpeg
```

On Windows:

```powershell
.\scripts\windows\host-preflight.ps1 -VMName <VM> -GpuMatch <GPU>
```
