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
4. The Mac trainer and the device runtime compute the same model: on a
   linear-regime adapter, `parity_check.py`'s transfer slope (Swift's
   effect against Python's) is in [0.9, 1.1]. It was 0.73 until the trainer
   matched the device's vision activation; it is now 1.015 on the smoke run
   (see below). Re-measure it on the first real run.

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

Measured 2026-10-07 on the development Mac (M2 Pro, 34 GB), on a 48-session
synthetic bundle (`run_smoke.py`).
- **Versions:**
  - Python side: mlx 0.32.3, mlx-vlm 0.7.6, Python 3.12.14.
  - Swift side: the app's vendored MLX core 0.31.1, mlx-swift-lm d2424294.
- **Training:**
  - 30 steps: rank 8, alpha 16 (scale 2.0), learning rate 1e-4, 504
    tensors over all 36 decoder layers.
  - Peak memory 17.3 GB, about 7 minutes.
  - Held-out first-slot accuracy went from 5/12 to 12/12, with one of four
    authored models held out. This is a toy counting task, not evidence.
- **Loading and identity:**
  - The converted adapter loads in Swift.
  - A zero-B adapter reproduces the baseline replay bit for bit on 48/48
    boards: generated text and probe probabilities alike. Both replays warm
    up first, as the app does at admission.
  - Without the warm-up, the first inference after a model load differed
    between two otherwise identical baseline replays. That was the only
    call that differed, so the harness now warms up by default.
- **Parity must be measured in the linear regime.**
  - The trained adapter moves slot log-odds by about 10 nats.
  - There, doubling its scale no longer doubles its effect: at 0.1 of its
    scale the effect is 3.4 times the 0.02 effect, not 5.
  - A ×2 canary at full scale once passed the original slope check by
    coincidence (slope 1.0), and the matched slope wandered (0.88–0.99).
  - The check therefore runs at 0.02 of the adapter's scale, where doubling
    the scale gives 2.3 times the effect in Python.
- **Parity at 0.02** (12 held-out boards, 35 log-odds points; before the
  trainer matched the device):
  - Swift's changes follow Python's: r = 0.95 at 0.02, 0.97 at 0.04.
  - The ×2 canary is clearly stronger: slope 1.69 against 0.73, a ratio of
    2.3, matching Python's own 2.3.
  - Prompt and image tokens match exactly (1,096 and 1,024).
  - So the converted adapter is applied as Python applies it, and a scale
    mix-up would show.
- **Transfer gap: cause found, 2026-10-07.**
  - **Symptom:** Swift showed 0.73 of Python's adapter effect at the same
    scale. Before any adapter, Swift's slot log-odds were 0.79 times
    Python's (r 0.88): a mean difference of 0.99 nats (max 2.75), with
    identical tokens.
  - **Cause:** the vision MLP activation.
    - The pinned model was trained with `gelu_pytorch_tanh`, and mlx-vlm
      computes that (`nn.GELU(approx="tanh")`).
    - The device runtime (mlx-swift-lm `d2424294`, `Qwen3VL.swift:655`)
      computes `GELU(approximation: .fast)`, i.e. `x·sigmoid(1.702x)`.
    - The two differ by up to 0.02 per activation, over 24 vision blocks
      and all three deepstack features.
  - **Checked and identical on both sides:** the prompt, the LoRA
    arithmetic, the probe readout, the mRoPE positions and the deepstack
    injection.
  - **Remedy:** the trainer computes what the device computes, so the
    device stays byte-identical. `common.match_device` gives every vision
    block the sigmoid GELU, and it is the default in `train_lora.py` and
    `eval_first_slot.py` (`--vision-gelu device`).
  - **Re-measured, 30 steps trained this way:**
    - Base slope 0.997, mean difference 0.087 nats (max 0.25), which is
      precision-level.
    - Transfer slope 1.015 (r 0.97).
    - The ×2 canary is 2.26, a ratio of 2.2.
    - Zero-B is still identical on 48/48 boards.
    - Held-out first slot goes from 3/12 to 12/12 (a toy task).
    - Peak memory 17.3 GB, about 5.5 minutes.
  - **Criterion 4 now holds on the smoke run.**
  - **Open, and not decided here:** whether the device should compute the
    trained activation instead is a device A/B (NEXT_STEPS §2).
