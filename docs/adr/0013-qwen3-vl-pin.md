# ADR 0013: The on-device VLM is Qwen3-VL-4B-Instruct-4bit

- Status: Accepted (amends the model identity in ADR 0003)
- Date: 2026-08-03

## Context

The Qwen2.5-VL-3B pin predates Qwen3-VL, whose 4B variant outperforms even
Qwen2.5-VL-7B on grounding and pointing — the exact capabilities the VLM's
remaining roles (advisory step check, recovery fallback, located hints)
depend on. An MLX 4-bit community build exists at roughly 3.5 GB, and the
pinned `mlx-swift-lm` revision already compiles Qwen3-VL model support.
Qwen3-VL reports grounding in relative 0–1 coordinates; the shipping
grammars are enum-only and unaffected, but prompts and any future
coordinate parsing must assume the new convention.

## Decision

Migrate to `mlx-community/Qwen3-VL-4B-Instruct-4bit` at immutable revision
`2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b` (3.09 GB safetensors) before any
new evaluation data is collected, so every benchmark row reflects the model
that ships. The
admission process of ADR 0003 is unchanged; its memory floor is re-measured
with the larger model and remains RECONSTRUCTED until physical-device runs
replace it. Prompts and grammars are re-validated on the smoke fixtures via
the bricky-harness CLI before the app switches.

## Consequences

Roughly 0.4 GB more weight against an already-tight budget, mitigated by
geometric-first verification and recovery (ADR 0008, ADR 0010) making VLM
residency on-demand rather than mandatory.

## Amendment (2026-09-25): the pin had never run

The first Mac run of the pinned weights, via the new weights-gated
`RecoveryRuntimeSmokeTests`, found two defects that would each have made
on-device admission reject every time. The warm-up is a real inference,
and it could neither load the model nor complete a call:

- **Stale shard index.** The pinned revision ships all weights in one
  `model.safetensors`, but its `model.safetensors.index.json` (left over
  from the unquantized upstream) names two shards that do not exist. The
  pinned loader prefers an index whenever one is present, so loading
  failed. `LoadableModelDirectory` now detects an index that names missing
  files and loads through a symlink directory without it. User files are
  not modified, and the asset list still mirrors the revision exactly.
- **No matcher fork.** At the pinned mlx-swift-lm commit,
  `GrammarConstraint.clone()` always throws ("Fork() not available in
  xgrammar v0.1.30"). The runtime now compiles a fresh matcher per call
  instead: about 7 ms per schema once the grammar tokenizer (about 0.7 s)
  is cached. Every schema is compiled once during warm-up so a bad schema
  fails admission, not recovery.

Any future pin bump must pass `RecoveryRuntimeSmokeTests` with
`BRICKY_MODEL_DIR` set before it ships.

