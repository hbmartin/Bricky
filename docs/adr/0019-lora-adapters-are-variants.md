# ADR 0019: A fine-tuned adapter is a model variant

- Status: Proposed. The tooling exists; no adapter is trained for use, and
  none ships, until the entry criteria below are met.
- Date: 2026-10-07

## Context

Roadmap §4.2.8 names LoRA fine-tuning of the pinned Qwen3-VL as the
training path, and NEXT_STEPS §5 sets its preconditions: the §2 A/B table
resolved, at least 150 labelled cases exported, and a stable scorer
baseline. Today the corpus has no real rows, so none of those hold. What
can be built without data is the plumbing, so that the first adapter is
measured by the same harness, rows and gates as every other variant.

Facts that shape the design:
- **Trainer.** Apple's adapter toolkit cannot target the OS 27 base models,
  and `mlx_lm`'s `save_config` deletes `vision_config`. The trainer is
  therefore mlx-vlm (Python).
- **Runtime.** The pinned mlx-swift-lm (`d2424294`) already loads LoRA
  adapters: `LoRAContainer.from(directory:)` reads `adapter_config.json`
  and `adapters.safetensors`, and `load(into:)` wraps the language model's
  linear layers. For Qwen3-VL it wraps the language model only, never the
  vision tower.
- **Two traps.** The Swift and Python scale defaults differ (10 against
  20), and `load(into:)` verifies only that no key is unused. A layer the
  file has no weights for keeps a random A and a zero B, so it is silently
  a no-op.
- **Leakage.** A model fine-tuned on one physical build and tested on the
  same build has learned the build, not the task. Sessions carried no
  identity for the physical build until `physical_build_id`.

## Decision (Proposed)

**An adapter is a variant (ADR 0010 amendment).** It is recorded as
`adapter=<name>@<sha12>` in `variant_id`, beside the other axes. The
baseline's encoding and id are unchanged when no adapter is set.

**Trainer and format.**
- **Trainer.** mlx-vlm LoRA on the language model only. Rank, alpha,
  dropout, learning rate, steps, seed and the projection keys are all
  explicit.
- **Converter.** `Tools/Training/convert_adapter.py` writes the
  mlx-swift-lm format. Every config spells out its `scale` (the effective
  multiplier) and its `keys`, and carries a `bricky` block: `name`,
  `base_model_revision`, `smoke`.
- **The runtime refuses** a config without an explicit scale, rank or keys;
  an unconverted mlx-vlm config (one with `alpha`); and a weights file
  missing any wrapped layer.
- **Adapters stay unfused**, so the base weights stay byte-identical, and
  a zero-B adapter reproduces the baseline exactly.

**Data.**
- **Pairs.** Training pairs come from evidence bundles: the exact stored
  board and the verbatim prompt, targeting the truth slot's first letter
  after the probe prefix.
- **Splits.** Train and test are split by authored model and by physical
  build, transitively: sessions sharing either stay on one side.
- **Excluded.** Never train an adapter for use on `replay:` or
  `synthetic:` rows, on judged or unlabeled rows, or without legal-use
  confirmation.

**Entry (before any adapter is trained for use).**
1. The NEXT_STEPS §2 A/B table is resolved.
2. At least 150 staged or confirmed sessions are exported, with at least
   2 split components on each side.
3. The scorer's baseline is stable.

**Exit (before an adapter becomes the default).**
1. An exact McNemar win against the baseline on held-out authored models,
   scored only on the test split (`compare_arms.py --restrict`).
2. Device rows under the ADR 0010 amendment, from floor devices.
3. `RecoveryRuntimeSmokeTests` and the adapter parity tests pass with the
   adapter (ADR 0013).

**Delivery to the app is deferred.** There is no adapter to ship, and
`RecoveryModelManager` assumes one model revision: it prunes every other
model folder, and the background transfer drops any other revision.
Delivering an adapter needs its own pinned, hashed asset and admission
with the adapter loaded. That design waits for an adapter worth shipping.

## Consequences

- **Smoke adapters.** The pipeline is proven end to end on synthetic smoke
  bundles. The adapter that proves it is named `smoke-…`; the release
  scorer refuses it, and it is never committed.
- **One more variant axis** for `compare_arms.py` to keep honest. Arms with
  different `model_revision`s are refused, and an adapter arm must be
  restricted to its test split.
- **Training is local only** (`Tools/Training/`, a uv project, not in CI).
  Its versions and measured parity tolerances are recorded here.

## Measured on the smoke run

Measured 2026-10-07 on the development Mac (M2 Pro, 34 GB). This was the
pipeline run step by step on a 48-session synthetic bundle; `run_smoke.py`
chains the same steps.
- **Versions:**
  - Python side: mlx 0.32.3, mlx-vlm 0.7.6, Python 3.12.14.
  - Swift side: the app's vendored MLX core 0.31.1, mlx-swift-lm d2424294.
- **Training:** 30 steps, rank 8, alpha 16 (scale 2.0), learning rate 1e-4,
  504 tensors over all 36 decoder layers. Peak memory 17.3 GB, 7 minutes.
  Held-out first-slot accuracy (one of four authored models held out) went
  from 5/12 to 12/12. That is a toy counting task, not evidence.
- **Loading and identity:** the converted adapter loads in Swift. A zero-B
  adapter reproduces the baseline replay bit for bit, both generated text
  and probe probabilities.
- **Parity** (`parity_check.py`, 12 held-out boards, 36 log-odds points):
  - Swift's change against Python's has slope 0.989: pass.
  - The ×2-scale canary has slope 0.49: it fails, as required.
  - Prompt and image tokens match exactly (1,096 and 1,024).
- **Open: the base models disagree.** Before any adapter, Python's and
  Swift's slot log-odds differ by 0.99 nats mean and 2.75 max. This is
  owed before real training (NEXT_STEPS §5).
