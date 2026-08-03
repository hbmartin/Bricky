#!/usr/bin/env python3
"""Regenerate pyldraw3 schema-v1 manifests and cumulative snapshots."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FIXTURES = ROOT / "fixtures"
GOLDEN = ROOT / "golden"
EXPECTED_GENERATOR_VERSION = "1.5.0"


def run(*arguments: str, environment: dict[str, str]) -> None:
    completed = subprocess.run(
        arguments, check=False, cwd=ROOT, env=environment, text=True, capture_output=True
    )
    if completed.returncode:
        sys.stdout.write(completed.stdout)
        sys.stderr.write(completed.stderr)
        completed.check_returncode()


def yaml_quoted(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def hermetic_environment(ldraw_root: Path, home: Path) -> dict[str, str]:
    """Build an environment that forces pyldraw3 onto the pinned library.

    pyldraw3 resolves its library exclusively through ``config.yml`` in the
    platformdirs user-config directory and otherwise falls back to its own
    download cache under the user's home; it reads no dedicated environment
    variable. Redirecting ``HOME`` (and the XDG dirs for Linux) to a private
    scratch directory makes the developer cache unreachable, and the written
    config points at the verified extracted release asset instead.
    """
    library_root = ldraw_root.parent
    config_body = (
        f"ldraw_library_path: {yaml_quoted(str(library_root))}\n"
        f"generated_path: {yaml_quoted(str(home / 'generated'))}\n"
    )
    for config_dir in (
        home / "Library" / "Application Support" / "pyldraw3",  # macOS platformdirs
        home / ".config" / "pyldraw3",  # Linux platformdirs (XDG)
    ):
        config_dir.mkdir(parents=True, exist_ok=True)
        (config_dir / "config.yml").write_text(config_body)

    environment = os.environ.copy()
    environment["HOME"] = str(home)
    environment["XDG_CONFIG_HOME"] = str(home / ".config")
    environment["XDG_CACHE_HOME"] = str(home / ".cache")
    environment["XDG_DATA_HOME"] = str(home / ".local" / "share")
    # Keep uv itself on the real cache/toolchain so `uv run` needs no network.
    for variable, command in (
        ("UV_CACHE_DIR", ["uv", "cache", "dir"]),
        ("UV_PYTHON_INSTALL_DIR", ["uv", "python", "dir"]),
    ):
        completed = subprocess.run(
            command, check=True, cwd=ROOT, text=True, capture_output=True
        )
        environment.setdefault(variable, completed.stdout.strip())
    return environment


def ensure_parts_lst(ldraw_root: Path, environment: dict[str, str]) -> None:
    """Generate parts.lst inside the extracted release asset when missing.

    The pinned complete.zip ships without parts.lst (LDraw expects mklist to
    produce it); reuse pyldraw3's own deterministic generator so diagnostics
    reference the pinned library rather than any machine-local cache.
    """
    if (ldraw_root / "parts.lst").is_file():
        return
    run(
        "uv",
        "run",
        "python",
        "-c",
        "import sys; from pathlib import Path; from ldraw.generate import generate_parts_lst; "
        "generate_parts_lst(mode='description', version_dir=Path(sys.argv[1]))",
        str(ldraw_root.parent),
        environment=environment,
    )


def normalized(value: object, roots: list[Path]) -> object:
    if isinstance(value, dict):
        result = {key: normalized(item, roots) for key, item in sorted(value.items())}
        if "generator" in result and isinstance(result["generator"], dict):
            version = result["generator"].get("version")
            if version != EXPECTED_GENERATOR_VERSION:
                raise SystemExit(
                    f"generator version {version!r} does not match pinned "
                    f"{EXPECTED_GENERATOR_VERSION!r}; update EXPECTED_GENERATOR_VERSION "
                    "deliberately instead of stamping stale provenance"
                )
        return result
    if isinstance(value, list):
        return [normalized(item, roots) for item in value]
    if isinstance(value, str):
        text = value.replace("\\", "/")
        for root in roots:
            text = text.replace(str(root).replace("\\", "/"), f"<{root.name}>")
        return text
    return value


STEP_DIRECTIVE = re.compile(r"^\s*0\s+STEP\s*$", re.IGNORECASE | re.MULTILINE)


def has_explicit_step(fixture: Path) -> bool:
    return bool(STEP_DIRECTIVE.search(fixture.read_text()))


def reject_invalid_fixtures(environment: dict[str, str]) -> None:
    fixtures = [
        fixture
        for fixture in sorted((FIXTURES / "invalid").glob("*"))
        if fixture.suffix.lower() in {".mpd", ".ldr"}
    ]
    if not fixtures:
        raise SystemExit("no invalid fixtures found; expected rejection corpus is missing")
    for fixture in fixtures:
        completed = subprocess.run(
            ["uv", "run", "ldraw", "instructions", "validate", str(fixture), "--strict"],
            check=False,
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
        )
        # A fixture counts as rejected when pyldraw3 strict validation fails,
        # or when it violates Bricky's stepped-model invariant (pyldraw3
        # tolerates unstepped models as a single implicit step; Bricky's
        # instruction pipeline does not).
        if completed.returncode == 0 and has_explicit_step(fixture):
            raise SystemExit(f"invalid fixture unexpectedly passed validation: {fixture.name}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ldraw-root", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    ldraw_root = arguments.ldraw_root.resolve()
    if ldraw_root.name != "ldraw" or not (ldraw_root / "parts").is_dir():
        raise SystemExit(
            f"--ldraw-root must point at the extracted asset's 'ldraw' directory "
            f"(containing parts/ and p/); got {ldraw_root}"
        )

    with tempfile.TemporaryDirectory(prefix="bricky-pyldraw3-home-") as scratch_home:
        environment = hermetic_environment(ldraw_root, Path(scratch_home))
        ensure_parts_lst(ldraw_root, environment)
        generate(arguments, ldraw_root, environment)


def generate(arguments: argparse.Namespace, ldraw_root: Path, environment: dict[str, str]) -> None:
    reject_invalid_fixtures(environment)

    generated = ROOT / ".generated-golden"
    shutil.rmtree(generated, ignore_errors=True)
    generated.mkdir()
    for fixture in sorted((FIXTURES / "valid").glob("*")):
        if fixture.suffix.lower() not in {".mpd", ".ldr"}:
            continue
        if not has_explicit_step(fixture):
            raise SystemExit(
                f"valid fixture {fixture.name} has no explicit '0 STEP'; "
                "unstepped models are not instructions"
            )
        output = generated / fixture.stem
        output.mkdir()
        manifest = output / "manifest.json"
        snapshots = output / "snapshots"
        run("uv", "run", "ldraw", "instructions", "validate", str(fixture), "--strict", environment=environment)
        run("uv", "run", "ldraw", "instructions", "export", str(fixture), "-o", str(manifest), environment=environment)
        run("uv", "run", "ldraw", "instructions", "snapshots", str(fixture), "--out", str(snapshots), environment=environment)
        # Most-specific roots first so ancestor replacements cannot shadow them.
        roots = [output, fixture.parent, ldraw_root, ROOT]
        payload = normalized(json.loads(manifest.read_text()), roots)
        manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        snapshot_manifest = snapshots / "instructions.json"
        snapshot_payload = normalized(json.loads(snapshot_manifest.read_text()), roots)
        snapshot_manifest.write_text(json.dumps(snapshot_payload, indent=2, sort_keys=True) + "\n")

    if arguments.check:
        result = subprocess.run(["diff", "-ru", str(GOLDEN), str(generated)], check=False)
        raise SystemExit(result.returncode)
    shutil.rmtree(GOLDEN, ignore_errors=True)
    generated.rename(GOLDEN)


if __name__ == "__main__":
    main()
