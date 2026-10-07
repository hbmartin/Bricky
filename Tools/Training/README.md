# Tools/Training — LoRA for the recovery VLM (ADR 0019)

Local tooling to fine-tune the pinned Qwen3-VL-4B on Bricky's evidence
bundles and replay the result as an `adapter=` variant. Nothing here runs
in CI, and nothing trained here ships: ADR 0019's entry criteria (the
NEXT_STEPS §2 A/B table resolved, at least 150 labelled sessions, a stable
baseline) are unmet. Until then, only the smoke pipeline runs.

```sh
cd Tools/Training && uv sync    # mlx 0.32.3, mlx-vlm 0.7.6 (uv.lock)
```

## The pipeline

1. **Export** pairs (stdlib, in `Tools/RecoveryEvaluation`):
   `python3 ../RecoveryEvaluation/export_training_pairs.py bundle … --out pairs`.
   This splits train and test by authored model and physical build.
2. **Template** from the Swift model (it needs the weights):
   `bricky-harness adapter-template --model-dir model --model-revision <sha> --out template`.
   This writes `template/template.json`, every adapter tensor's name, shape
   and dtype, and a zero-B adapter.
3. **Train**:
   `uv run python train_lora.py --model-dir model --pairs pairs --out trained/mlx_vlm`.
   - LoRA wraps the seven projections of every language-model decoder layer
     and never the vision tower.
   - The loss covers the reply only. The reply begins with the probe's prefix
     and names the truth slot first.
   - Each step computes the frozen vision embeddings outside the gradient;
     differentiating through the vision tower for a 1,024-token board does
     not fit in 32 GB.
   - `training_manifest.json` records every hyperparameter, the library
     versions and the peak memory.
4. **Convert**:
   `uv run python convert_adapter.py --input trained/mlx_vlm --template template/template.json --out trained/swift --name <name> --base-revision <sha>`.
   It checks names, shapes and layers against the template, and writes
   mlx-swift-lm's config with an explicit scale (mlx-vlm's is
   `alpha / rank`; the Swift defaults are 10 and 20, so a missing scale
   would be off by up to 10×). It casts to the model's dtype and prints the
   identity `name@sha12`.
5. **Replay** in Swift as a variant:
   `bricky-harness replay … --adapter trained/swift`, then
   `compare_arms.py --restrict pairs/split_manifest.json`.
6. **Score in Python** (optional):
   `uv run python eval_first_slot.py --model-dir model --pairs pairs --adapter trained/swift --out eval.jsonl`.
   This gives first-slot accuracy on the held-out split, posed exactly as
   the runtime poses it.

## Parity and the smoke run

`run_smoke.py` runs the whole pipeline on a synthetic smoke bundle
(`bricky-harness synth-bundle`). It then checks three things:
- **Loading:** the converted adapter loads in Swift. Any missing layer, stray
  tensor or wrong dtype is refused.
- **Parity:** `parity_check.py`. Python and Swift share no MLX build, so it
  compares the change the adapter makes to each slot's log-odds against the
  truth slot. Swift's change against Python's must have a slope in
  [0.9, 1.1], and prompt and image token counts must match exactly. A
  canary converted at twice the scale must fail the same check.
- **Identity:** a zero-B adapter reproduces the baseline bit for bit
  (`RecoveryAdapterSmokeTests`, and the C9 replay).

Smoke adapters are named `smoke-…`. The release scorer refuses them, and
they are never committed.

## Tests

`python3 -m unittest test_training_tools.py` tests the converter's planning
and the parity arithmetic without MLX.
