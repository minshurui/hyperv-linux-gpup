#!/usr/bin/env python3
"""Validate and optionally extract a WSL driver archive without trusting tar metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import tarfile
from typing import Any

SCHEMA = "hyperv-linux-gpup/wsl-driver-archive/v1"
MANIFEST_NAME = "MANIFEST.json"
PAYLOAD_ROOT = PurePosixPath("usr/lib/wsl")
ALLOWED_ANCESTORS = {"usr", "usr/lib", "usr/lib/wsl"}
DEFAULT_MAX_MEMBERS = 20_000
DEFAULT_MAX_FILE_SIZE = 2 * 1024**3
DEFAULT_MAX_TOTAL_SIZE = 8 * 1024**3
MAX_MANIFEST_SIZE = 4 * 1024**2
CHUNK_SIZE = 1024**2


class ValidationError(Exception):
    pass


def canonical_path(name: str) -> PurePosixPath:
    if not name or "\\" in name or "\x00" in name:
        raise ValidationError(f"invalid member path: {name!r}")
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise ValidationError(f"non-canonical member path: {name!r}")
    if str(path) != name.rstrip("/"):
        raise ValidationError(f"non-canonical member path: {name!r}")
    return path


def is_payload_path(path: PurePosixPath) -> bool:
    return path == PAYLOAD_ROOT or PAYLOAD_ROOT in path.parents


def member_kind(member: tarfile.TarInfo) -> str:
    if member.isfile():
        return "file"
    if member.isdir():
        return "directory"
    if member.issym():
        return "symlink"
    raise ValidationError(f"unsupported member type for {member.name!r}")


def confined_link(path: PurePosixPath, target: str) -> None:
    if not target or "\\" in target or "\x00" in target:
        raise ValidationError(f"invalid symlink target for {path}: {target!r}")
    target_path = PurePosixPath(target)
    if target_path.is_absolute():
        raise ValidationError(f"absolute symlink target for {path}: {target!r}")
    resolved: list[str] = list(path.parent.parts)
    for part in target_path.parts:
        if part in ("", "."):
            continue
        if part == "..":
            if not resolved:
                raise ValidationError(f"symlink escapes archive root: {path} -> {target}")
            resolved.pop()
        else:
            resolved.append(part)
    destination = PurePosixPath(*resolved)
    if not is_payload_path(destination):
        raise ValidationError(f"symlink escapes payload root: {path} -> {target}")


def read_manifest(archive: Path, members: dict[str, tarfile.TarInfo]) -> dict[str, Any]:
    manifest_member = members.get(MANIFEST_NAME)
    if manifest_member is None or not manifest_member.isfile():
        raise ValidationError(f"archive must contain one regular {MANIFEST_NAME}")
    if manifest_member.size > MAX_MANIFEST_SIZE:
        raise ValidationError(f"{MANIFEST_NAME} exceeds {MAX_MANIFEST_SIZE} bytes")
    with tarfile.open(archive, "r:*") as handle:
        extracted = handle.extractfile(manifest_member)
        if extracted is None:
            raise ValidationError(f"cannot read {MANIFEST_NAME}")
        raw = extracted.read(MAX_MANIFEST_SIZE + 1)
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"invalid {MANIFEST_NAME}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValidationError(f"{MANIFEST_NAME} must be a JSON object")
    return value


def scan_archive(
    archive: Path, max_members: int, max_file_size: int, max_total_size: int
) -> tuple[dict[str, tarfile.TarInfo], int]:
    members: dict[str, tarfile.TarInfo] = {}
    total_size = 0
    try:
        with tarfile.open(archive, "r:*") as handle:
            for index, member in enumerate(handle, start=1):
                if index > max_members:
                    raise ValidationError(f"archive exceeds member limit ({max_members})")
                path = canonical_path(member.name)
                name = str(path)
                if name in members:
                    raise ValidationError(f"duplicate archive member: {name}")
                kind = member_kind(member)
                if member.mode & (stat.S_ISUID | stat.S_ISGID):
                    raise ValidationError(f"setuid/setgid mode is not allowed: {name}")
                if kind == "file":
                    if member.size < 0 or member.size > max_file_size:
                        raise ValidationError(f"file exceeds size limit: {name}")
                    total_size += member.size
                    if total_size > max_total_size:
                        raise ValidationError(
                            f"archive exceeds total regular-file limit ({max_total_size} bytes)"
                        )
                elif member.size != 0:
                    raise ValidationError(f"non-file member has data: {name}")
                if name != MANIFEST_NAME and not is_payload_path(path) and name not in ALLOWED_ANCESTORS:
                    raise ValidationError(f"member outside payload allowlist: {name}")
                if kind == "symlink":
                    confined_link(path, member.linkname)
                members[name] = member
    except (tarfile.TarError, OSError) as exc:
        raise ValidationError(f"cannot read archive: {exc}") from exc
    return members, total_size


def validate_manifest(
    archive: Path, manifest: dict[str, Any], members: dict[str, tarfile.TarInfo]
) -> dict[str, dict[str, Any]]:
    if set(manifest) != {"schema", "created", "source", "files"}:
        raise ValidationError("manifest keys do not match the v1 schema")
    if manifest.get("schema") != SCHEMA:
        raise ValidationError(f"unsupported manifest schema: {manifest.get('schema')!r}")
    if not isinstance(manifest.get("created"), str) or not manifest["created"]:
        raise ValidationError("manifest created must be a non-empty string")
    if not isinstance(manifest.get("source"), str) or not manifest["source"]:
        raise ValidationError("manifest source must be a non-empty string")
    entries = manifest.get("files")
    if not isinstance(entries, list):
        raise ValidationError("manifest files must be an array")

    allowlist: dict[str, dict[str, Any]] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValidationError("each manifest file entry must be an object")
        path_value = entry.get("path")
        if not isinstance(path_value, str):
            raise ValidationError("manifest entry path must be a string")
        path = canonical_path(path_value)
        name = str(path)
        if name == MANIFEST_NAME or not is_payload_path(path) and name not in ALLOWED_ANCESTORS:
            raise ValidationError(f"manifest path outside payload allowlist: {name}")
        if name in allowlist:
            raise ValidationError(f"duplicate manifest entry: {name}")
        kind = entry.get("type")
        expected_keys: set[str]
        if kind == "file":
            expected_keys = {"path", "type", "size", "sha256", "mode"}
            digest = entry.get("sha256")
            size = entry.get("size")
            if not isinstance(size, int) or isinstance(size, bool) or size < 0:
                raise ValidationError(f"invalid manifest size for {name}")
            if not isinstance(digest, str) or len(digest) != 64 or any(
                char not in "0123456789abcdef" for char in digest
            ):
                raise ValidationError(f"invalid SHA-256 for {name}")
        elif kind == "directory":
            expected_keys = {"path", "type", "mode"}
        elif kind == "symlink":
            expected_keys = {"path", "type", "target"}
            target = entry.get("target")
            if not isinstance(target, str):
                raise ValidationError(f"invalid symlink target for {name}")
            confined_link(path, target)
        else:
            raise ValidationError(f"invalid manifest type for {name}: {kind!r}")
        if set(entry) != expected_keys:
            raise ValidationError(f"manifest keys do not match type {kind!r} for {name}")
        if kind != "symlink":
            mode = entry.get("mode")
            if not isinstance(mode, int) or isinstance(mode, bool) or not 0 <= mode <= 0o777:
                raise ValidationError(f"invalid mode for {name}")
        allowlist[name] = entry

    archive_payload = set(members) - {MANIFEST_NAME}
    if set(allowlist) != archive_payload:
        missing = sorted(set(allowlist) - archive_payload)
        extra = sorted(archive_payload - set(allowlist))
        raise ValidationError(f"manifest/archive allowlist mismatch; missing={missing!r}, extra={extra!r}")

    required = "usr/lib/wsl/lib/nvidia-smi"
    required_entry = allowlist.get(required)
    if required_entry is None or required_entry.get("type") != "file" or not required_entry["mode"] & 0o111:
        raise ValidationError(f"manifest must contain executable regular file {required}")

    with tarfile.open(archive, "r:*") as handle:
        for name, entry in allowlist.items():
            member = members[name]
            kind = member_kind(member)
            if kind != entry["type"]:
                raise ValidationError(f"member type differs from manifest: {name}")
            if kind == "file":
                if member.size != entry["size"] or stat.S_IMODE(member.mode) != entry["mode"]:
                    raise ValidationError(f"file metadata differs from manifest: {name}")
                source = handle.extractfile(member)
                if source is None:
                    raise ValidationError(f"cannot read file member: {name}")
                digest = hashlib.sha256()
                while chunk := source.read(CHUNK_SIZE):
                    digest.update(chunk)
                if digest.hexdigest() != entry["sha256"]:
                    raise ValidationError(f"SHA-256 mismatch: {name}")
            elif kind == "directory":
                if stat.S_IMODE(member.mode) != entry["mode"]:
                    raise ValidationError(f"directory mode differs from manifest: {name}")
            elif member.linkname != entry["target"]:
                raise ValidationError(f"symlink target differs from manifest: {name}")
    return allowlist


def ensure_no_symlink_parent(path: PurePosixPath, kinds: dict[str, str]) -> None:
    for parent in path.parents:
        if str(parent) == ".":
            break
        if kinds.get(str(parent)) == "symlink":
            raise ValidationError(f"member traverses symlink parent: {path}")


def extract_validated(
    archive: Path, destination: Path, members: dict[str, tarfile.TarInfo], allowlist: dict[str, dict[str, Any]]
) -> None:
    if destination.exists():
        if not destination.is_dir() or any(destination.iterdir()):
            raise ValidationError(f"extraction directory must be empty: {destination}")
    else:
        destination.mkdir(mode=0o700, parents=True)
    if destination.is_symlink():
        raise ValidationError(f"extraction directory must not be a symlink: {destination}")
    os.chmod(destination, 0o700)

    kinds = {name: entry["type"] for name, entry in allowlist.items()}
    for name in kinds:
        ensure_no_symlink_parent(PurePosixPath(name), kinds)

    directories = sorted(
        (name for name, entry in allowlist.items() if entry["type"] == "directory"),
        key=lambda name: (len(PurePosixPath(name).parts), name),
    )
    for name in directories:
        target = destination.joinpath(*PurePosixPath(name).parts)
        target.mkdir(mode=0o700, parents=True, exist_ok=True)
        if target.is_symlink():
            raise ValidationError(f"refusing symlink directory during extraction: {name}")

    with tarfile.open(archive, "r:*") as handle:
        for name in sorted(allowlist):
            entry = allowlist[name]
            if entry["type"] != "file":
                continue
            target = destination.joinpath(*PurePosixPath(name).parts)
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            source = handle.extractfile(members[name])
            if source is None:
                raise ValidationError(f"cannot extract file member: {name}")
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(target, flags, 0o600)
            try:
                with os.fdopen(descriptor, "wb") as output:
                    while chunk := source.read(CHUNK_SIZE):
                        output.write(chunk)
                os.chmod(target, entry["mode"], follow_symlinks=False)
            except Exception:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
                raise

    for name in sorted(allowlist):
        entry = allowlist[name]
        if entry["type"] != "symlink":
            continue
        target = destination.joinpath(*PurePosixPath(name).parts)
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.symlink(entry["target"], target)

    for name in sorted(directories, key=lambda value: len(PurePosixPath(value).parts), reverse=True):
        target = destination.joinpath(*PurePosixPath(name).parts)
        os.chmod(target, allowlist[name]["mode"], follow_symlinks=False)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--extract", type=Path, metavar="EMPTY_DIRECTORY")
    parser.add_argument("--max-members", type=int, default=DEFAULT_MAX_MEMBERS)
    parser.add_argument("--max-file-size", type=int, default=DEFAULT_MAX_FILE_SIZE)
    parser.add_argument("--max-total-size", type=int, default=DEFAULT_MAX_TOTAL_SIZE)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if min(args.max_members, args.max_file_size, args.max_total_size) <= 0:
        print("ERROR: validation limits must be positive", file=sys.stderr)
        return 2
    try:
        archive = args.archive.resolve(strict=True)
        if not archive.is_file():
            raise ValidationError(f"archive is not a regular file: {archive}")
        members, total_size = scan_archive(
            archive, args.max_members, args.max_file_size, args.max_total_size
        )
        manifest = read_manifest(archive, members)
        allowlist = validate_manifest(archive, manifest, members)
        if args.extract is not None:
            extract_validated(archive, args.extract, members, allowlist)
    except (ValidationError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    action = "validated and extracted" if args.extract is not None else "validated"
    print(f"Archive {action}: {len(members)} members, {total_size} regular-file bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
