#!/usr/bin/env python3
"""Convert an mlx-vlm LoRA adapter to the mlx-swift-lm format the app's
runtime loads (ADR 0019).

    uv run python convert_adapter.py --input trained/mlx_vlm --template zero-b/template.json \\
        --out trained/swift --name first-slot.v1 --base-revision <sha>

The template comes from `bricky-harness adapter-template` and is read from
the Swift model itself, so every tensor's name, shape and dtype is checked
against what the runtime will wrap. The output config spells out rank,
scale and keys, which the runtime requires, and the tensors are cast to the
model's dtype: the Swift LoRA layer adds its term without casting, so a
float32 adapter would turn a bfloat16 model's activations into float32.

--zero-b writes B as zeros (the replay must then equal the baseline), and
--scale-multiplier scales the written scale: a test-only canary that the
parity check must catch.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

from common import LAYER_PREFIX, NAME_PATTERN, identity


@dataclass
class Plan:
    num_layers: int
    layers: list[int]
    keys: list[str]
    rank: int
    scale: float
    transpose: set[str] = field(default_factory=set)


def parse_name(name: str) -> tuple[int, str, str]:
    """(layer, key, half) from `<prefix><layer>.<key>.lora_a|lora_b`."""
    if not name.startswith(LAYER_PREFIX):
        raise ValueError(f"unexpected tensor {name}: not a language-model decoder layer")
    rest = name[len(LAYER_PREFIX):]
    layer, _, tail = rest.partition(".")
    if not layer.isdigit():
        raise ValueError(f"unexpected tensor {name}")
    for half in ("lora_a", "lora_b"):
        if tail.endswith("." + half):
            return int(layer), tail[: -len(half) - 1], half
    raise ValueError(f"unexpected tensor {name}: not lora_a or lora_b (a legacy A/B adapter?)")


def plan(config: dict[str, object], shapes: dict[str, list[int]], template: dict[str, object]) -> Plan:
    """Checks an mlx-vlm adapter against the Swift template and decides what
    the converted file holds. Pure: no MLX."""
    if "alpha" in config or "rank" in config:
        raise ValueError("a legacy mlx-vlm adapter (top-level rank/alpha, A/B tensors); train with get_peft_model")
    if config.get("fine_tune_type", "lora") != "lora":
        raise ValueError(f"fine_tune_type {config.get('fine_tune_type')} is not supported; only lora")
    parameters = dict(config["lora_parameters"])
    rank, scale = int(parameters["rank"]), float(parameters["scale"])

    halves: dict[int, dict[str, set[str]]] = {}
    for name in sorted(shapes):
        layer, key, half = parse_name(name)
        halves.setdefault(layer, {}).setdefault(key, set()).add(half)
    if not halves:
        raise ValueError("the adapter holds no tensors")
    layers = sorted(halves)
    keys = sorted({key for per_layer in halves.values() for key in per_layer})
    template_keys = set(template["keys"])
    unknown = sorted(set(keys) - template_keys)
    if unknown:
        raise ValueError(f"keys {unknown} are not wrapped by the Swift model ({sorted(template_keys)})")
    for layer in layers:
        for key in keys:
            if halves[layer].get(key) != {"lora_a", "lora_b"}:
                raise ValueError(f"layer {layer} {key} lacks lora_a or lora_b")
    total = int(template["total_layers"])
    if layers != list(range(total - len(layers), total)):
        raise ValueError(f"layers {layers[0]}…{layers[-1]} are not the model's last {len(layers)} of {total}")

    transpose = set()
    tensors = dict(template["tensors"])
    for name, shape in shapes.items():
        layer, key, half = parse_name(name)
        reference = tensors.get(name)
        if reference is None:
            raise ValueError(f"{name} is not in the template")
        if half == "lora_a":
            expected = [reference[0], rank]
        else:
            expected = [rank, reference[1]]
        if list(shape) == expected:
            continue
        if list(reversed(shape)) == expected:
            transpose.add(name)
            continue
        raise ValueError(f"{name} has shape {list(shape)}, the Swift model needs {expected}")
    return Plan(num_layers=len(layers), layers=layers, keys=keys, rank=rank, scale=scale, transpose=transpose)


def swift_config(plan: Plan, *, name: str, base_revision: str, smoke: bool, scale_multiplier: float) -> dict[str, object]:
    return {
        "fine_tune_type": "lora",
        "num_layers": plan.num_layers,
        "lora_parameters": {"rank": plan.rank, "scale": plan.scale * scale_multiplier, "keys": plan.keys},
        "bricky": {"name": name, "base_model_revision": base_revision, "smoke": smoke},
    }


def check_name(name: str, *, smoke: bool) -> None:
    if not NAME_PATTERN.match(name):
        raise ValueError(f"adapter name {name} must match [a-z0-9._-]+")
    if smoke != name.startswith("smoke-"):
        raise ValueError("smoke adapters, and only they, are named smoke-…")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--input", type=Path, required=True, help="mlx-vlm adapter directory")
    parser.add_argument("--template", type=Path, required=True, help="template.json from bricky-harness adapter-template")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--base-revision", required=True, help="the pinned model revision it was trained on")
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--zero-b", action="store_true", help="write B as zeros")
    parser.add_argument("--scale-multiplier", type=float, default=1.0, help="test-only canary")
    arguments = parser.parse_args(argv)
    if arguments.scale_multiplier != 1.0 and not arguments.smoke:
        raise SystemExit("--scale-multiplier is a test canary; it needs --smoke")

    import mlx.core as mx

    check_name(arguments.name, smoke=arguments.smoke)
    config = json.loads((arguments.input / "adapter_config.json").read_text())
    template = json.loads(arguments.template.read_text())
    arrays = mx.load(str(arguments.input / "adapters.safetensors"))
    conversion = plan(config, {name: list(array.shape) for name, array in arrays.items()}, template)
    dtype = {"BF16": mx.bfloat16, "F16": mx.float16, "F32": mx.float32}[template["dtype"]]
    converted = {}
    for name, array in arrays.items():
        if name in conversion.transpose:
            array = array.T
        if arguments.zero_b and name.endswith(".lora_b"):
            array = mx.zeros_like(array)
        converted[name] = array.astype(dtype)
    arguments.out.mkdir(parents=True, exist_ok=True)
    (arguments.out / "adapter_config.json").write_text(json.dumps(
        swift_config(conversion, name=arguments.name, base_revision=arguments.base_revision, smoke=arguments.smoke,
                     scale_multiplier=arguments.scale_multiplier),
        indent=2, sort_keys=True,
    ) + "\n")
    mx.save_safetensors(str(arguments.out / "adapters.safetensors"), converted)
    adapter_identity, full = identity(arguments.out, arguments.name)
    print(
        f"{adapter_identity} (sha256 {full}): {len(converted)} tensors over layers "
        f"{conversion.layers[0]}…{conversion.layers[-1]}, rank {conversion.rank}, "
        f"scale {conversion.scale * arguments.scale_multiplier:g}, {template['dtype']}"
        + (f", {len(conversion.transpose)} transposed" if conversion.transpose else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
