# Troubleshooting

## VM does not expose `1414:008e`

On an elevated Windows PowerShell:

```powershell
Get-VMHostPartitionableGpu
Get-VMGpuPartitionAdapter -VMName <VM>
```

The VM must be off before changing adapters. Run `host-preflight.ps1`; if more
than one adapter exists, use `configure-gpup.ps1 -Action Apply` to consolidate
it. Do not attempt to bind the Linux `nvidia.ko` PCI driver to `1414:008e`.

## `dxgkrnl` logs MMIO/BAR allocation errors

The GPU-P device needs guest-controlled cache types and sufficient MMIO:

```powershell
Set-VM -Name <VM> -GuestControlledCacheTypes $true `
  -LowMemoryMappedIoSpace 1GB -HighMemoryMappedIoSpace 32GB
```

Only run this while the VM is off. Larger GPUs or other passthrough devices may
need a different value; 32GB is a tested starting point, not a universal law.

## Custom kernel boots but network is absent

Do not immediately assume `hv_netvsc` is missing. Boot the distribution kernel
and inspect the failed boot:

```bash
sudo ./scripts/linux/diagnose-boot.sh -1 ./state
journalctl -b -1 | grep -iE 'ordering cycle|deleted to break'
```

A socket unit with an unnecessary `After=network.target` can create an ordering
cycle and cause systemd to discard NetworkManager's start job. Also verify the
kernel config contains Hyper-V network/storage and initramfs support.

## `nvidia-smi` fails although `/dev/dxg` exists

GPU-P uses the Windows host driver through `dxgkrnl`. A normal Debian NVIDIA
DKMS package is not the user-mode bridge. Re-export both locations from the
same machine's working WSL distribution:

```text
/usr/lib/wsl/lib
/usr/lib/wsl/drivers/nv*.inf_amd64_*
```

Run `print-driver-env.sh` after installing. A Windows NVIDIA driver update may
change the DriverStore directory hash; never copy an old hard-coded path from
another computer.

## DKMS reports unknown symbols

Kernel modules are tied to the exact kernel ABI and symbol versions. Never copy
an NVIDIA `.ko` built for another kernel. For GPU-P, ordinary NVIDIA DKMS does
not bind the Microsoft virtual PCI device anyway. Preserve the error log, boot
the distribution kernel and rebuild the custom kernel cleanly.

## `nvidia-smi` works but Emby hardware transcoding fails

Check all three layers:

1. Container has `/dev/dxg`.
2. Container mounts `/usr/lib/wsl/lib` and `/usr/lib/wsl/drivers` read-only.
3. The effective `LD_LIBRARY_PATH` retains the application's own paths and adds
   the versioned DriverStore directory.

Then run:

```bash
sudo ./scripts/linux/validate-emby-compose.sh /path/docker-compose.yml emby /bin/ffmpeg
```

The script performs a real one-second NVENC encode followed by NVDEC decode.
`nvidia-smi` alone is not an encoder/decoder acceptance test.

## Recovery

Never delete distribution kernels. Use the Hyper-V console to choose the old
kernel from GRUB. Persistent defaults require `GRUB_DEFAULT=saved`; the helper
script backs up `/etc/default/grub` before enabling that mode.
