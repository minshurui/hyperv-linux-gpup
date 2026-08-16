# hyperv-linux-gpup

可复现的 Hyper-V Linux GPU-P / `dxgkrnl` 方法与检测脚本。

> **本项目只发布方法、检查和本地编译脚本。** 不发布编译好的 Linux 内核、NVIDIA/Microsoft 驱动、VM 磁盘或任何凭据。用户必须在自己的 Windows/WSL/Debian 环境中自行下载、编译和提取所需组件，并遵守各自许可证。

[![CI](https://github.com/minshurui/hyperv-linux-gpup/actions/workflows/ci.yml/badge.svg)](https://github.com/minshurui/hyperv-linux-gpup/actions/workflows/ci.yml)

## 适用场景

目标架构是：

```text
Windows + Hyper-V GPU-P
        ↓
Debian/Ubuntu x86_64 VM
        ↓
Microsoft dxgkrnl (/dev/dxg)
        ↓
本机 WSL NVIDIA 用户态库
        ↓
FFmpeg / Emby NVDEC + NVENC
```

它不是 DDA 教程。GPU-P 让 Windows 宿主机继续使用显卡；DDA 是整卡独占直通，不适合本项目的共享目标。

## 重要限制

- 需要 Windows/Hyper-V 暴露可分区 GPU：`Get-VMHostPartitionableGpu` 必须可用。
- GPU-P、Hyper-V PowerShell 参数和 WSL 驱动布局会随 Windows/GPU 驱动版本变化。
- Generation 1/2、Secure Boot、发行版内核配置可能不同；脚本会检测并在不确定时停止或告警。
- 本项目不承诺所有机器都能成功。先执行 preflight，再显式执行 Apply。
- 定制内核不是 Debian 官方内核；它不会随着 Debian 内核更新自动获得安全修复。

## 两条实现路线

- **通用整内核路线**：适合普通 Debian/Ubuntu 客体，见下方快速流程。
- **保留厂商内核的外部模块路线**：已在 fnOS `6.18.18.c952-trim` 上验证，避免替换内核导致厂商 RAID/存储初始化缺失。参见 [`docs/FNOS-6.18.md`](docs/FNOS-6.18.md)，使用 `build-dxg-module-6.18.sh`、精确 `Module.symvers` 预检以及可回滚安装脚本。

外部模块路线仍是窄版本移植，只接受经哈希验证的 Microsoft tag `linux-msft-wsl-6.6.87.2`（commit `427645e3db3a8896714f22a3d3fe0c3f7b317ad4`），不代表任意 WSL 源码和 Linux 6.18 内核均兼容。完整支持边界与可复现来源记录见 [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md)。

## 快速流程

### 1. Windows 宿主机（管理员 PowerShell）

只检查：

```powershell
.\scripts\windows\host-preflight.ps1 -VMName Debian-Migrated -GpuMatch "RTX 3070"
```

关机后应用 GPU-P、去除重复适配器并配置 MMIO：

```powershell
.\scripts\windows\configure-gpup.ps1 `
  -VMName Debian-Migrated -GpuMatch "RTX 3070" -Action Apply -Confirm:$false
```

脚本默认设置：

- `GuestControlledCacheTypes = true`
- Low MMIO：1GB
- High MMIO：32GB
- VM 只保留一个 GPU-P adapter

状态文件默认写入 `state/`，不会提交到 Git。回滚前必须关闭 VM：

```powershell
.\scripts\windows\configure-gpup.ps1 `
  -VMName Debian-Migrated -Action Rollback -Confirm:$false
```

### 2. WSL 中导出本机用户态驱动

在已能运行 `nvidia-smi` 的 NVIDIA WSL 发行版内执行：

```bash
sudo ./scripts/linux/export-wsl-driver.sh \
  --output /mnt/c/Users/<you>/Downloads/wsl-nvidia-driver.tar.gz
sudo ./scripts/linux/export-wsl-driver.sh \
  --output /mnt/c/Users/<you>/Downloads/wsl-nvidia-driver.tar.gz --apply
```

导出默认仅预览，必须显式加 `--apply` 才会写归档。归档包含 `MANIFEST.json`、逐文件 SHA-256 和完整成员 allowlist。该脚本只从本机读取 `/usr/lib/wsl/lib` 和可匹配的 `/usr/lib/wsl/drivers` 子目录。生成的归档包含专有文件，**不要提交 GitHub**。安全格式、验证限制与威胁模型见 [`docs/WSL-DRIVER-ARCHIVES.md`](docs/WSL-DRIVER-ARCHIVES.md)。

### 3. Debian VM 安装依赖并编译

先检查：

```bash
sudo ./scripts/linux/guest-preflight.sh
```

安装编译依赖（明确修改系统前加 `--apply`）：

```bash
sudo ./scripts/linux/install-build-deps.sh --apply
```

下载 Microsoft WSL2 Kernel 源码时，请选择包含 `drivers/hv/dxgkrnl` 的稳定 tag，并自行阅读上游许可证。示例：

```bash
git clone --depth 1 --branch linux-msft-wsl-6.6.87.2 \
  https://github.com/microsoft/WSL2-Linux-Kernel.git \
  /usr/src/WSL2-Linux-Kernel-6.6.87.2
```

以当前 Debian 内核配置为基础编译，不发布二进制：

```bash
sudo ./scripts/linux/build-dxg-kernel.sh \
  --source /usr/src/WSL2-Linux-Kernel-6.6.87.2 \
  --base-config /boot/config-$(uname -r) \
  --output ./dxg-kernel-artifacts
```

脚本强制启用 DXG/Hyper-V 关键项，但保留发行版配置以避免丢失根磁盘、ext4、initramfs 或网卡支持。构建产物只留在本机 `dxg-kernel-artifacts/`。

安装编译出的 `.deb`，但不切换默认内核：

```bash
sudo ./scripts/linux/install-kernel-packages.sh \
  --directory ./dxg-kernel-artifacts \
  --kernel-version 6.6.87.2-dxg-hyperv --apply
```

### 4. 一次性测试启动

持久默认项使用 GRUB saved mode。先检查，确认后再备份并启用：

```bash
sudo ./scripts/linux/prepare-grub-saved.sh
sudo ./scripts/linux/prepare-grub-saved.sh --apply
```

一次性测试启动本身不依赖 saved mode。先只显示目标 GRUB 项：

```bash
sudo ./scripts/linux/set-grub-kernel.sh \
  --kernel-version 6.6.87.2-dxg-hyperv --mode once
```

确认无误后设置一次性启动：

```bash
sudo ./scripts/linux/set-grub-kernel.sh \
  --kernel-version 6.6.87.2-dxg-hyperv --mode once --apply
sudo reboot
```

启动后检查：

```bash
uname -r
ls -l /dev/dxg
sudo ./scripts/linux/validate-gpu.sh
```

如果启动失败，Hyper-V 控制台选择原 Debian 内核；不要删除原内核。也可以从仍运行的稳定内核执行：

```bash
sudo ./scripts/linux/set-grub-kernel.sh \
  --kernel-version 6.12.101+deb13-amd64 --mode default --apply
```

### 5. 安装 WSL 用户态库

先检查归档，不修改系统：

```bash
sudo ./scripts/linux/install-wsl-driver.sh \
  --archive /path/to/wsl-nvidia-driver.tar.gz
```

确认归档来自可信的本机 WSL 后再安装：

```bash
sudo ./scripts/linux/install-wsl-driver.sh \
  --archive /path/to/wsl-nvidia-driver.tar.gz --apply
```

安装会保留显式回滚记录；默认先预览，确认后恢复此前的驱动树：

```bash
sudo ./scripts/linux/rollback-wsl-driver.sh
sudo ./scripts/linux/rollback-wsl-driver.sh --apply
```

然后再次运行：

```bash
sudo ./scripts/linux/validate-gpu.sh
```

### 6. Emby Compose

不要把驱动拷进镜像；通过 Compose 挂载宿主机用户态库和 `/dev/dxg`。先打印本机实际 DriverStore 搜索路径：

```bash
./scripts/linux/print-driver-env.sh
```

如果应用需要版本化 DriverStore 库，把输出的 `LD_LIBRARY_PATH` 合并到 Compose；不要写死其他机器的 `nv*.inf_amd64_<hash>`。配置可参考：

```bash
docker compose -f docker-compose.yml \
  -f examples/compose.gpup.override.yml config
```

确认配置后只重建 Emby，并运行：

```bash
sudo ./scripts/linux/validate-emby-compose.sh /path/to/docker-compose.yml emby
```

最终必须实际验证 NVDEC 和 NVENC；`nvidia-smi` 单独成功不等于 Emby 硬解成功。

## 这次迁移遇到的关键坑

| 现象 | 根因 | 方法性修复 |
|---|---|---|
| DDA 失败/宿主显卡受影响 | 笔记本 GPU 不适合整卡独占 | 使用 GPU-P，不使用 DDA |
| VM 中有两个 `1414:008e` | 重复添加 GPU-P adapter | 关机后收敛为一个 |
| 普通 NVIDIA DKMS 不工作 | GPU-P 暴露 Microsoft 设备，不是 NVIDIA PCI 设备 | 使用 `dxgkrnl` + WSL 用户态库 |
| 模块 `Unknown symbol` | 跨内核复制 `.ko` | 每个内核重新编译，GPU-P 不依赖普通 `nvidia.ko` |
| 启动后没有网络 | socket unit 的 `After=network.target` 造成 systemd 排序循环 | 移除不必要的网络排序依赖 |
| `dxgkrnl` MMIO 错误 | GPU-P BAR/MMIO 空间不足 | 开启 GuestControlledCacheTypes，增加高位 MMIO |
| `nvidia-smi` 找不到驱动 | 只同步了 WSL 通用库 | 同步匹配的 `/usr/lib/wsl/drivers` |
| 主机可见 GPU、Emby 不可用 | 容器未映射设备和用户态库 | Compose 映射 `/dev/dxg`、WSL 库和 DriverStore |
| rclone `mount not ready` | 旧 VFS 写缓存重放过期上传任务 | 只读媒体挂载、前台监督、旧缓存隔离 |

## 诊断

启动失败或失联后，在控制台进入稳定内核，再收集：

```bash
sudo ./scripts/linux/diagnose-boot.sh -1 ./state
```

重点查看：

```bash
dmesg | grep -iE 'dxg|hyper-v|netvsc|mmio|1414:008e'
journalctl -b -p warning..alert
systemctl --failed
```

## 许可证与第三方文件

本仓库脚本以 MIT 发布。Microsoft WSL2 Kernel、NVIDIA 驱动和其他第三方组件按其各自许可证处理；本仓库不重新分发这些二进制文件。
