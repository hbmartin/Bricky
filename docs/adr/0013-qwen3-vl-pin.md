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

Migrate to a pinned immutable revision of
`mlx-community/Qwen3-VL-4B-Instruct-4bit` before any new evaluation data is
collected, so every benchmark row reflects the model that ships. The
admission process of ADR 0003 is unchanged; its memory floor is re-measured
with the larger model and remains RECONSTRUCTED until physical-device runs
replace it. Prompts and grammars are re-validated on the smoke fixtures via
the bricky-harness CLI before the app switches.

## Consequences

Roughly 0.4 GB more weight against an already-tight budget, mitigated by
geometric-first verification and recovery (ADR 0008, ADR 0010) making VLM
residency on-demand rather than mandatory.
