"""Shared pieces of the training tools (ADR 0019)."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

EXPORT_SCHEMA = "bricky.training_export.v1"
LAYER_PREFIX = "language_model.model.layers."
NAME_PATTERN = re.compile(r"^[a-z0-9._-]+$")
# The decoder projections LoRA wraps: every linear in a Qwen3-VL language
# model layer. The vision tower is never wrapped.
PROJECTION_KEYS = ("q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj")


def read_jsonl(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def read_export(directory: Path, *, smoke: bool) -> dict[str, object]:
    """The exporter's manifest, refused if it is not one, if it found
    leakage, or if its smoke flag does not match `smoke`."""
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest.get("schema") != EXPORT_SCHEMA:
        raise SystemExit(f"{directory} is not an export_training_pairs.py output")
    if manifest["leakage"]["violations"]:
        raise SystemExit(f"{directory} has identities on both sides of its split")
    if manifest["smoke"] and not smoke:
        raise SystemExit(f"{directory} is a smoke export; pass --smoke to use it for a pipeline test")
    if smoke and not manifest["smoke"]:
        raise SystemExit(f"{directory} is a real export; a smoke run must not train on it")
    return manifest


def pair_image(directory: Path, pair: dict[str, object]) -> str:
    path = Path(str(pair["image_path"]))
    return str(path if path.is_absolute() else directory / path)


def conversation(pair: dict[str, object], *, with_target: bool) -> list[dict[str, str]]:
    """The turn the runtime sends — one user message, the board and the
    verbatim prompt — and, for training, the target as the reply."""
    turns = [{"role": "user", "content": str(pair["prompt"])}]
    if with_target:
        turns.append({"role": "assistant", "content": str(pair["target_text"])})
    return turns


def identity(directory: Path, name: str) -> tuple[str, str]:
    """`name@sha12` and the full hash, exactly as RecoveryAdapter computes
    them: SHA-256 of the config bytes followed by the weights bytes."""
    digest = hashlib.sha256()
    digest.update((directory / "adapter_config.json").read_bytes())
    digest.update((directory / "adapters.safetensors").read_bytes())
    full = digest.hexdigest()
    return f"{name}@{full[:12]}", full
