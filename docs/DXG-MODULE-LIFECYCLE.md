# Transactional dxg module lifecycle

The external `dxgkrnl` lifecycle scripts are conservative system-change tools. All
three entry points are dry-run by default and serialize changes with one shared
`flock` lock.

## Install

```bash
sudo ./scripts/linux/install-dxg-module.sh ./dxgkrnl.ko
sudo ./scripts/linux/install-dxg-module.sh ./dxgkrnl.ko --apply
```

An applied install:

1. Runs exact-ABI preflight before changing the system.
2. Captures the original module, loader, unloader, unit, enabled state, active
   state, and whether `dxgkrnl` was loaded.
3. Writes an immutable transaction under
   `/var/lib/hyperv-linux-gpup/<kernel>/transactions/<id>/`.
4. Stops the service without ignoring failure and confirms `dxgkrnl` is absent
   from `/proc/modules` before replacing anything on disk.
5. Stages each replacement in its destination directory and renames it
   atomically, so staging and destination are on the same filesystem.
6. Enables and starts the unit. Any `ERR` restores the captured snapshot.

The `current` marker contains the committed install transaction ID. Transaction
snapshots are append-only and made non-writable after completion; they are never
rewritten as mutable "latest state".

## Rollback

```bash
sudo ./scripts/linux/rollback-dxg-module.sh
sudo ./scripts/linux/rollback-dxg-module.sh --apply
```

By default rollback restores the snapshot belonging to the current committed
install. A specific snapshot may be selected explicitly:

```bash
sudo ./scripts/linux/rollback-dxg-module.sh \
  --transaction /var/lib/hyperv-linux-gpup/$(uname -r)/transactions/<id> --apply
```

Rollback itself creates a transaction first, so an error while restoring files
or service state rolls back the rollback. It never replaces the on-disk module
until service stop succeeds and module unload is confirmed.

## Safe uninstall

```bash
sudo ./scripts/linux/uninstall-dxg-module.sh
sudo ./scripts/linux/uninstall-dxg-module.sh --apply
```

Uninstall is explicit and refuses ambiguous partial state. It requires the
current transaction marker and all managed files, then stops/unloads, disables
the unit, removes only the managed module/loader/unloader/unit, reloads systemd,
and clears `current`. Immutable transaction history remains for audit. An error
restores the pre-uninstall snapshot.

Never force-unload `dxgkrnl`. If `/dev/dxg` is in use, the installed unloader
fails and the lifecycle operation stops before disk replacement.

## Tests

The fault-injection test uses a fake root and fake `systemctl`; it does not load a
module or modify the host:

```bash
bash tests/dxg-module-lifecycle-test.sh
```

It covers default dry-run, fresh install/uninstall, immutable state, automatic
rollback after a staged failure, and non-ignored service-stop failure.
