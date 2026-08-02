#!/usr/bin/env python3
"""Regenerate pyldraw3 schema-v1 manifests and cumulative snapshots."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FIXTURES = ROOT / "fixtures"
GOLDEN = ROOT / "golden"


def run(*arguments: str, environment: dict[str, str]) -> None:
    completed = subprocess.run(arguments, check=False, env=environment, text=True, capture_output=True)
    if completed.returncode:
        sys.stdout.write(completed.stdout)
        sys.stderr.write(completed.stderr)
        completed.check_returncode()


def normalized(value: object, roots: list[Path]) -> object:
    if isinstance(value, dict):
        result = {key: normalized(item, roots) for key, item in sorted(value.items())}
        if "generator" in result and isinstance(result["generator"], dict):
            result["generator"]["version"] = "1.5.0"
        return result
    if isinstance(value, list):
        return [normalized(item, roots) for item in value]
    if isinstance(value, str):
        text = value.replace("\\", "/")
        for root in roots:
            text = text.replace(str(root).replace("\\", "/"), f"<{root.name}>")
        return text
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ldraw-root", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    environment = os.environ.copy()
    environment["LDRAW_LIBRARY_PATH"] = str(arguments.ldraw_root.resolve())

    generated = ROOT / ".generated-golden"
    shutil.rmtree(generated, ignore_errors=True)
    generated.mkdir()
    for fixture in sorted((FIXTURES / "valid").glob("*")):
        if fixture.suffix.lower() not in {".mpd", ".ldr"}:
            continue
        output = generated / fixture.stem
        output.mkdir()
        manifest = output / "manifest.json"
        snapshots = output / "snapshots"
        run("uv", "run", "ldraw", "instructions", "validate", str(fixture), "--strict", environment=environment)
        run("uv", "run", "ldraw", "instructions", "export", str(fixture), "-o", str(manifest), environment=environment)
        run("uv", "run", "ldraw", "instructions", "snapshots", str(fixture), "--out", str(snapshots), environment=environment)
        payload = normalized(json.loads(manifest.read_text()), [ROOT, fixture.parent, output])
        manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        snapshot_manifest = snapshots / "instructions.json"
        snapshot_payload = normalized(json.loads(snapshot_manifest.read_text()), [ROOT, fixture.parent, output])
        snapshot_manifest.write_text(json.dumps(snapshot_payload, indent=2, sort_keys=True) + "\n")

    if arguments.check:
        result = subprocess.run(["diff", "-ru", str(GOLDEN), str(generated)], check=False)
        raise SystemExit(result.returncode)
    shutil.rmtree(GOLDEN, ignore_errors=True)
    generated.rename(GOLDEN)


if __name__ == "__main__":
    main()
