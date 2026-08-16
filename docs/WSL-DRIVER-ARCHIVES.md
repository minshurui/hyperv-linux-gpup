# WSL driver archive security

WSL driver archives contain proprietary binaries copied from the local machine. Treat an archive as untrusted input even when it is transferred between machines you control. Do not commit or redistribute it.

## Export

Export is a dry-run unless `--apply` is explicit:

```bash
sudo ./scripts/linux/export-wsl-driver.sh \
  --output /mnt/c/Users/<you>/Downloads/wsl-nvidia-driver.tar.gz
sudo ./scripts/linux/export-wsl-driver.sh \
  --output /mnt/c/Users/<you>/Downloads/wsl-nvidia-driver.tar.gz --apply
```

The exporter copies only `/usr/lib/wsl/lib` and matching NVIDIA DriverStore directories. It writes `MANIFEST.json` with a fixed schema and an allowlist entry for every payload directory, regular file, and symbolic link. Regular-file entries record mode, byte size, and SHA-256. The archive itself is written through a private temporary file and moved into place only after creation succeeds.

Record or compare the whole-archive SHA-256 printed by the exporter when transferring through an untrusted channel. The in-archive hashes detect payload changes but are not a signature: an attacker able to replace both archive and manifest can recompute them.

## Validation and installation

Validation is the installer's default and makes no system change:

```bash
sudo ./scripts/linux/install-wsl-driver.sh --archive /path/wsl-nvidia-driver.tar.gz
```

Before extraction, `validate-wsl-driver-archive.py` rejects:

- absolute, non-canonical, backslash, `..`, duplicate, or out-of-allowlist paths;
- devices, FIFOs, sockets, hard links, and all member types except directories, regular files, and confined symbolic links;
- symlinks that resolve outside `usr/lib/wsl`, or members nested beneath a symlink;
- excessive member counts, individual file sizes, or aggregate uncompressed sizes;
- missing, extra, malformed, or duplicate manifest allowlist entries;
- member type/mode/size/link mismatches and SHA-256 mismatches;
- archives without an executable regular `usr/lib/wsl/lib/nvidia-smi`.

Default limits are 20,000 members, 2 GiB per regular file, 8 GiB total regular-file content, and 4 MiB for `MANIFEST.json`.

Install only after validation succeeds:

```bash
sudo ./scripts/linux/install-wsl-driver.sh \
  --archive /path/wsl-nvidia-driver.tar.gz --apply
```

The installer extracts with Python's explicit file creation into a root-only staging directory on `/usr/lib`; it does not call `tar -x`. It installs by renaming the validated staged tree, retains the previous tree as `/usr/lib/wsl.before-<timestamp>`, and writes root-only rollback state to `/var/lib/hyperv-linux-gpup/wsl-driver-rollback.json`. A new install refuses to overwrite an unresolved rollback record.

## Explicit rollback

Rollback is also dry-run by default:

```bash
sudo ./scripts/linux/rollback-wsl-driver.sh
sudo ./scripts/linux/rollback-wsl-driver.sh --apply
```

Rollback restores the recorded previous tree, refreshes the `nvidia-smi` link and linker cache, and retains the replaced tree as `/usr/lib/wsl.rolled-back-<timestamp>`. If no tree existed before installation, rollback removes the installed path from service but still retains it at that timestamped location.

If post-install `nvidia-smi` validation fails, the installer immediately restores the prior tree and retains the failed tree as `/usr/lib/wsl.failed-<timestamp>`.

## Tests

```bash
bash tests/test-wsl-driver-archive.sh
bash tests/lint.sh
```

Fixtures are generated at test time and cover a valid archive plus traversal, absolute path, escaping symlink, outside-allowlist path, special member, duplicate member, hash mismatch, unlisted member, and resource-limit rejection cases. No driver binaries are stored in the repository.
