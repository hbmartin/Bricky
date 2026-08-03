#!/usr/bin/env python3
"""Verify and stage the immutable LDraw 2026-07 Bricky release asset."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path, PurePosixPath
from zipfile import ZipFile

VERSION = "2026-07"
EXPECTED_BYTES = 144_722_356
EXPECTED_SHA256 = "6009f2e94204c4d3a63a4c812010b5c90bad8c5acb19b882c859fdac63734eae"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("--out-dir", type=Path, required=True)
    arguments = parser.parse_args()

    if arguments.archive.stat().st_size != EXPECTED_BYTES:
        raise SystemExit(f"unexpected archive size: {arguments.archive.stat().st_size}")
    actual_hash = digest(arguments.archive)
    if actual_hash != EXPECTED_SHA256:
        raise SystemExit(f"unexpected archive SHA-256: {actual_hash}")

    roots: set[str] = set()
    with ZipFile(arguments.archive) as archive:
        for name in archive.namelist():
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts:
                raise SystemExit(f"unsafe archive member: {name}")
            if path.parts:
                roots.add(path.parts[0].lower())
        if "ldraw" not in roots:
            raise SystemExit("archive does not contain the expected ldraw root")

    pyldraw_version = subprocess.run(
        ["uv", "run", "ldraw", "version"],
        check=True,
        text=True,
        capture_output=True,
        cwd=Path(__file__).resolve().parent,
    ).stdout.strip()
    arguments.out_dir.mkdir(parents=True, exist_ok=True)
    output = arguments.out_dir / "complete.zip"
    shutil.copyfile(arguments.archive, output)
    manifest = {
        "archive": output.name,
        "bytes": EXPECTED_BYTES,
        "ldraw_version": VERSION,
        "pyldraw3": pyldraw_version,
        "sha256": EXPECTED_SHA256,
    }
    (arguments.out_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )


if __name__ == "__main__":
    main()
