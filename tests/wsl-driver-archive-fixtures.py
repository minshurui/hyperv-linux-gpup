#!/usr/bin/env python3
"""Generate small good and malicious WSL driver archive fixtures."""

from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile

SCHEMA = "hyperv-linux-gpup/wsl-driver-archive/v1"


def directory(name: str, mode: int = 0o755) -> tuple[tarfile.TarInfo, bytes | None]:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = mode
    return info, None


def regular(name: str, value: bytes, mode: int = 0o644) -> tuple[tarfile.TarInfo, bytes]:
    info = tarfile.TarInfo(name)
    info.size = len(value)
    info.mode = mode
    return info, value


def symlink(name: str, target: str) -> tuple[tarfile.TarInfo, bytes | None]:
    info = tarfile.TarInfo(name)
    info.type = tarfile.SYMTYPE
    info.linkname = target
    info.mode = 0o777
    return info, None


def manifest_entry(info: tarfile.TarInfo, value: bytes | None) -> dict[str, object]:
    if info.isdir():
        return {"path": info.name, "type": "directory", "mode": info.mode}
    if info.issym():
        return {"path": info.name, "type": "symlink", "target": info.linkname}
    assert value is not None
    return {
        "path": info.name,
        "type": "file",
        "size": len(value),
        "sha256": hashlib.sha256(value).hexdigest(),
        "mode": info.mode,
    }


def write_archive(path: Path, payload: list[tuple[tarfile.TarInfo, bytes | None]], *, manifest_payload=None) -> None:
    if manifest_payload is None:
        manifest_payload = [manifest_entry(info, value) for info, value in payload]
    manifest = {
        "schema": SCHEMA,
        "created": "2025-01-01T00:00:00Z",
        "source": "test fixture",
        "files": manifest_payload,
    }
    encoded = (json.dumps(manifest, sort_keys=True) + "\n").encode()
    manifest_info, manifest_data = regular("MANIFEST.json", encoded, 0o600)
    with tarfile.open(path, "w:gz") as archive:
        for info, value in [(manifest_info, manifest_data), *payload]:
            archive.addfile(info, io.BytesIO(value) if value is not None else None)


def base() -> list[tuple[tarfile.TarInfo, bytes | None]]:
    return [
        directory("usr"),
        directory("usr/lib"),
        directory("usr/lib/wsl"),
        directory("usr/lib/wsl/lib"),
        regular("usr/lib/wsl/lib/nvidia-smi", b"#!/bin/sh\necho fixture\n", 0o755),
        regular("usr/lib/wsl/lib/libcuda.so.1", b"fixture-library\n", 0o644),
        symlink("usr/lib/wsl/lib/libcuda.so", "libcuda.so.1"),
    ]


def main() -> None:
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    good = base()
    write_archive(output / "good.tar.gz", good)

    traversal = base() + [regular("usr/lib/wsl/../../escape", b"bad")]
    write_archive(output / "traversal.tar.gz", traversal)

    absolute = base() + [regular("/absolute", b"bad")]
    write_archive(output / "absolute.tar.gz", absolute)

    escaping_link = base() + [symlink("usr/lib/wsl/lib/escape", "../../../../etc/passwd")]
    write_archive(output / "escaping-link.tar.gz", escaping_link)

    extra = base() + [regular("etc/shadow", b"bad")]
    write_archive(output / "outside-allowlist.tar.gz", extra)

    fifo = tarfile.TarInfo("usr/lib/wsl/lib/fifo")
    fifo.type = tarfile.FIFOTYPE
    fifo.mode = 0o600
    special_base = base()
    write_archive(
        output / "special-member.tar.gz",
        special_base + [(fifo, None)],
        manifest_payload=[manifest_entry(info, value) for info, value in special_base],
    )

    duplicate = base() + [regular("usr/lib/wsl/lib/libcuda.so.1", b"duplicate")]
    write_archive(output / "duplicate.tar.gz", duplicate)

    bad_hash_payload = base()
    bad_hash_manifest = [manifest_entry(info, value) for info, value in bad_hash_payload]
    for entry in bad_hash_manifest:
        if entry["path"] == "usr/lib/wsl/lib/libcuda.so.1":
            entry["sha256"] = "0" * 64
    write_archive(output / "bad-hash.tar.gz", bad_hash_payload, manifest_payload=bad_hash_manifest)

    missing_allowlist = [manifest_entry(info, value) for info, value in base()][:-1]
    write_archive(output / "unlisted-member.tar.gz", base(), manifest_payload=missing_allowlist)


if __name__ == "__main__":
    main()
