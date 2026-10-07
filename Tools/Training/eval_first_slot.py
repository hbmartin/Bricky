#!/usr/bin/env python3
"""Score exported pairs by the first ranking slot, the decision the probe
reads, with or without a converted adapter (ADR 0019).

    uv run python eval_first_slot.py --model-dir model --pairs pairs --split test \\
        --adapter trained/swift --out eval.jsonl

Each pair is posed exactly as the runtime poses it: one user turn with the
board and the verbatim prompt, the generation prompt, then the probe's
prefix. The log-probability of every slot letter at the next position is
recorded, with the prompt and image token counts, so parity_check.py can
compare them with the Swift replay of the same boards. The adapter is the
converted (Swift-format) one, applied the way the Swift runtime applies it,
so both sides run the same tensors.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from common import conversation, pair_image, read_jsonl


def apply_swift_adapter(model, directory: Path) -> None:
    """Wraps the model's last `num_layers` decoder layers on the adapter's
    keys and loads its tensors, as RecoveryAdapter does in Swift."""
    import mlx.core as mx
    from mlx_vlm.trainer.lora_layers import LoRALinear
    from mlx_vlm.trainer.utils import get_module_by_name, set_module_by_name

    config = json.loads((directory / "adapter_config.json").read_text())
    parameters = config["lora_parameters"]
    layers = model.language_model.model.layers
    for layer in range(len(layers) - int(config["num_layers"]), len(layers)):
        for key in parameters["keys"]:
            name = f"language_model.model.layers.{layer}.{key}"
            set_module_by_name(model, name, LoRALinear.from_base(
                get_module_by_name(model, name), r=int(parameters["rank"]), scale=float(parameters["scale"]),
                dropout=0.0,
            ))
    model.load_weights(list(mx.load(str(directory / "adapters.safetensors")).items()), strict=False)
    mx.eval(model.parameters())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--pairs", type=Path, required=True)
    parser.add_argument("--split", choices=("train", "test"), default="test")
    parser.add_argument("--adapter", type=Path, help="a converted adapter directory")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--limit", type=int, help="score only the first N pairs")
    arguments = parser.parse_args(argv)

    import mlx.core as mx
    from PIL import Image
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import load, process_inputs_with_fallback

    pairs = read_jsonl(arguments.pairs / f"{arguments.split}.jsonl")[: arguments.limit]
    model, processor = load(str(arguments.model_dir))
    if arguments.adapter:
        apply_swift_adapter(model, arguments.adapter)
    config = model.config.__dict__
    tokenizer = processor.tokenizer
    image_token = int(config.get("image_token_id") or config.get("image_token_index"))
    rows, correct = [], 0
    for pair in pairs:
        prompt = apply_chat_template(
            processor, config, conversation(pair, with_target=False), add_generation_prompt=True, num_images=1,
        ) + str(pair["probe_prefix"])
        image = Image.open(pair_image(arguments.pairs, pair)).convert("RGB")
        inputs = process_inputs_with_fallback(
            processor=processor, prompts=[prompt], images=[image], audio=None, add_special_tokens=False,
        )
        if "images" in inputs and "pixel_values" not in inputs:
            inputs["pixel_values"] = inputs.pop("images")
        input_ids = mx.array(inputs["input_ids"])
        extra = {
            key: mx.array(value) for key, value in inputs.items()
            if key not in ("input_ids", "pixel_values", "attention_mask")
        }
        outputs = model(input_ids, mx.array(inputs["pixel_values"]), mx.array(inputs["attention_mask"]), **extra)
        logits = outputs.logits[0, -1, :].astype(mx.float32)
        logprobs = logits - mx.logsumexp(logits)
        letters = [chr(ord("A") + index) for index in range(int(pair["slot_count"]))]
        slot_logprobs = {}
        for letter in letters:
            ids = tokenizer.encode(letter, add_special_tokens=False)
            if len(ids) != 1:
                raise SystemExit(f"slot letter {letter} is {len(ids)} tokens; the probe assumes one")
            slot_logprobs[letter] = float(logprobs[ids[0]].item())
        first = max(letters, key=lambda letter: slot_logprobs[letter])
        correct += first == pair["truth_slot"]
        flat = [int(token) for token in mx.array(inputs["input_ids"]).reshape(-1).tolist()]
        rows.append({
            "trace_id": pair["trace_id"],
            "session_id": pair["session_id"],
            "truth_slot": pair["truth_slot"],
            "first_slot": first,
            "correct": first == pair["truth_slot"],
            "slot_logprobs": slot_logprobs,
            "prompt_tokens": len(flat),
            "image_tokens": sum(1 for token in flat if token == image_token),
        })
    arguments.out.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows))
    print(f"first-slot accuracy {correct}/{len(rows)} on {arguments.split}"
          + (f" with {arguments.adapter.name}" if arguments.adapter else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
