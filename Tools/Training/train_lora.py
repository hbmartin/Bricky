#!/usr/bin/env python3
"""Train a LoRA adapter on exported pairs with mlx-vlm (ADR 0019).

    uv run python train_lora.py --model-dir model --pairs pairs --out trained/mlx_vlm

Trains on train.jsonl only, never test.jsonl. LoRA wraps the seven
projections of every language-model decoder layer and nothing in the
vision tower; rank, alpha, dropout, learning rate, steps and seed are all
explicit and recorded in training_manifest.json, with the library
versions and the peak memory. The loss covers the reply alone, so the
board and prompt are context, not targets. The vision
tower's embeddings are computed before each step and kept out of the
gradient: it is frozen, and differentiating through it does not fit.
Convert the result with convert_adapter.py before replaying it in Swift.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

from common import LAYER_PREFIX, PROJECTION_KEYS, conversation, pair_image, read_export, read_jsonl


def encode(model, processor, config, directory: Path, pair: dict[str, object]):
    """Token ids for the whole turn, the index where the reply starts, and
    the frozen embeddings (text and vision) for those ids, evaluated now so
    the gradient never reaches the vision tower: carrying it through the
    backward pass of a 1,024-token board does not fit in 32 GB."""
    import mlx.core as mx
    from PIL import Image
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import process_inputs_with_fallback

    image = Image.open(pair_image(directory, pair)).convert("RGB")

    def tokens(messages, generation_prompt: bool):
        prompt = apply_chat_template(
            processor, config, messages, add_generation_prompt=generation_prompt, num_images=1,
        )
        inputs = process_inputs_with_fallback(
            processor=processor, prompts=[prompt], images=[image], audio=None, add_special_tokens=False,
        )
        if "images" in inputs and "pixel_values" not in inputs:
            inputs["pixel_values"] = inputs.pop("images")
        return inputs

    context = tokens(conversation(pair, with_target=False), True)
    full = tokens(conversation(pair, with_target=True), False)
    context_ids = mx.array(context["input_ids"]).reshape(-1).tolist()
    input_ids = mx.array(full["input_ids"])
    if input_ids.reshape(-1).tolist()[: len(context_ids)] != context_ids:
        raise SystemExit(f"pair {pair['trace_id']}: the reply does not extend the prompt's tokens")
    extra = {
        key: mx.array(value) for key, value in full.items() if key not in ("input_ids", "pixel_values", "attention_mask")
    }
    features = model.get_input_embeddings(input_ids, mx.array(full["pixel_values"]), **extra).to_dict()
    features = {key: value for key, value in features.items() if value is not None}
    mx.eval(list(features.values()))
    return input_ids, len(context_ids), features


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--pairs", type=Path, required=True, help="an export_training_pairs.py output")
    parser.add_argument("--out", type=Path, required=True, help="where mlx-vlm writes the adapter")
    parser.add_argument("--smoke", action="store_true", help="accept a smoke export (pipeline test only)")
    parser.add_argument("--rank", type=int, default=8)
    parser.add_argument("--alpha", type=float, default=16.0, help="scale is alpha / rank")
    parser.add_argument("--dropout", type=float, default=0.0)
    parser.add_argument("--learning-rate", type=float, default=1e-4)
    parser.add_argument("--iters", type=int, default=200)
    parser.add_argument("--seed", type=int, default=0)
    arguments = parser.parse_args(argv)

    export = read_export(arguments.pairs, smoke=arguments.smoke)
    pairs = read_jsonl(arguments.pairs / "train.jsonl")
    if not pairs:
        raise SystemExit("train.jsonl is empty")

    import mlx.core as mx
    import mlx.nn as nn
    import mlx.optimizers as optim
    import mlx_vlm
    import numpy as np
    from mlx.utils import tree_flatten
    from mlx_vlm.trainer.utils import get_peft_model, save_adapter
    from mlx_vlm.utils import load

    mx.random.seed(arguments.seed)
    np.random.seed(arguments.seed)
    started = time.time()
    model, processor = load(str(arguments.model_dir))
    config = model.config.__dict__
    model = get_peft_model(
        model, list(PROJECTION_KEYS), rank=arguments.rank, alpha=arguments.alpha, dropout=arguments.dropout,
        verbose=False,
    )
    trainable = [name for name, _ in tree_flatten(model.trainable_parameters())]
    stray = [name for name in trainable if not name.startswith(LAYER_PREFIX)]
    if stray or not trainable:
        raise SystemExit(f"only language-model decoder layers may train; found {stray[:5] or 'nothing'}")

    arguments.out.mkdir(parents=True, exist_ok=True)

    def loss_fn(model, input_ids, start, features):
        logits = model.language_model(input_ids, mask=None, cache=None, pixel_values=None, **features).logits
        logits = logits[:, :-1, :].astype(mx.float32)
        labels = input_ids[:, 1:]
        # Only the reply is a target: positions from its first token on.
        positions = mx.arange(labels.shape[1])[None, :]
        mask = (positions >= start - 1).astype(mx.float32)
        losses = nn.losses.cross_entropy(logits, labels, reduction="none")
        return (losses * mask).sum() / mx.maximum(mask.sum(), 1)

    loss_and_grad = nn.value_and_grad(model, loss_fn)
    optimizer = optim.Adam(learning_rate=arguments.learning_rate)
    order = np.random.permutation(len(pairs))
    losses = []
    for step in range(arguments.iters):
        pair = pairs[int(order[step % len(order)])]
        input_ids, start, features = encode(model, processor, config, arguments.pairs, pair)
        loss, gradients = loss_and_grad(model, input_ids, start, features)
        optimizer.update(model, gradients)
        mx.eval(model.trainable_parameters(), optimizer.state, loss)
        losses.append(float(loss.item()))
        if step % 10 == 0 or step == arguments.iters - 1:
            print(f"step {step + 1}/{arguments.iters} loss {losses[-1]:.4f}", flush=True)
    save_adapter(model, arguments.out / "adapters.safetensors")
    manifest = {
        "schema": "bricky.training_run.v1",
        "versions": {"mlx": mx.__version__, "mlx_vlm": mlx_vlm.__version__, "python": sys.version.split()[0]},
        "export": {
            "path": str(arguments.pairs),
            "manifest_sha256": hashlib.sha256((arguments.pairs / "manifest.json").read_bytes()).hexdigest(),
            "smoke": export["smoke"],
            "train_pairs": len(pairs),
        },
        "lora": {
            "rank": arguments.rank, "alpha": arguments.alpha, "scale": arguments.alpha / arguments.rank,
            "dropout": arguments.dropout, "keys": list(PROJECTION_KEYS), "trainable_tensors": len(trainable),
        },
        "optimizer": {"name": "adam", "learning_rate": arguments.learning_rate},
        "iters": arguments.iters,
        "loss_first_10": sum(losses[:10]) / len(losses[:10]),
        "loss_last_10": sum(losses[-10:]) / len(losses[-10:]),
        "seed": arguments.seed,
        "peak_memory_bytes": int(mx.get_peak_memory()),
        "seconds": round(time.time() - started, 1),
    }
    (arguments.out / "training_manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"trained {len(trainable)} tensors on {len(pairs)} pairs; peak {manifest['peak_memory_bytes'] / 1e9:.1f} GB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
