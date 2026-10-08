#!/usr/bin/env python3
"""Check that the Swift runtime applies a converted adapter as Python does
(ADR 0019).

    python3 parity_check.py --python-base base.jsonl --python-adapter adapted.jsonl \
        --swift-base base.ndjson.traces.ndjson --swift-adapter adapted.ndjson.traces.ndjson \
        --swift-canary canary.ndjson.traces.ndjson

Inputs are eval_first_slot.py outputs and `bricky-harness replay --scoring
probe` trace sidecars of the same boards: the adapter at one scale on both
sides, and a canary of the same adapter at twice that scale in Swift. For
every board and every slot other than the truth, the change the adapter
makes to the log-odds against the truth slot is compared, Python against
Swift. Log-odds between slot letters do not depend on how either side
normalises.

Run it in the linear regime: convert the adapter with a small
--scale-multiplier (the smoke uses 0.02). A trained adapter moves log-odds
by ~10 nats, where doubling its scale no longer doubles its effect.

It fails (plumbing) when:
- prompt or image token counts differ;
- the changes do not correlate (r < 0.9): Swift is not applying the same
  adapter;
- the doubled-scale canary is not clearly stronger than the adapter
  (slope ratio < 1.5): a scale mix-up such as Swift's defaults of 10 or 20
  against mlx-vlm's alpha / rank would go unseen.
It reports, without failing, the transfer slope (Swift's change against
Python's at the same scale) beside the slope of Swift's base log-odds on
Python's. They differ from 1 when the two runtimes compute different
models. ADR 0019 requires the transfer slope in [0.9, 1.1] before any
real training, not for the smoke. Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

# What ADR 0019 asks of the transfer slope before real training.
TRANSFER_RANGE = (0.9, 1.1)
# Changes smaller than this (in nats) carry no slope information.
MINIMUM_EFFECT = 0.05
MINIMUM_CORRELATION = 0.9
# A doubled scale must show at least this much stronger in Swift.
MINIMUM_CANARY_RATIO = 1.5


def read_jsonl(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def swift_logprobs(trace: dict[str, object]) -> dict[str, float]:
    """Slot letter -> log probability at the probe's final decision."""
    readouts = trace.get("readouts") or []
    if not readouts:
        raise SystemExit(f"trace {trace.get('trace_id')} has no readouts; replay with --scoring probe")
    final = readouts[-1]
    letters = {}
    for candidate in final["candidates"]:
        text = str(candidate["text"]).strip()
        if len(text) == 1 and text.isupper() and candidate["probability"] > 0:
            letters[text] = math.log(float(candidate["probability"]))
    return letters


def log_odds(logprobs: dict[str, float], truth: str) -> dict[str, float]:
    return {slot: value - logprobs[truth] for slot, value in logprobs.items() if slot != truth}


def compare(
    python_base: list[dict[str, object]],
    python_adapter: list[dict[str, object]],
    swift_base: list[dict[str, object]],
    swift_adapter: list[dict[str, object]],
) -> dict[str, object]:
    by_id = {name: {str(row["trace_id"]): row for row in rows} for name, rows in (
        ("python_base", python_base), ("python_adapter", python_adapter),
        ("swift_base", swift_base), ("swift_adapter", swift_adapter),
    )}
    shared = sorted(set.intersection(*(set(rows) for rows in by_id.values())))
    points, base_errors, token_mismatches, base_pairs = [], [], [], []
    for trace_id in shared:
        truth = str(by_id["python_base"][trace_id]["truth_slot"])
        python_base_odds = log_odds(dict(by_id["python_base"][trace_id]["slot_logprobs"]), truth)
        python_adapter_odds = log_odds(dict(by_id["python_adapter"][trace_id]["slot_logprobs"]), truth)
        swift_base_odds = log_odds(swift_logprobs(by_id["swift_base"][trace_id]), truth)
        swift_adapter_odds = log_odds(swift_logprobs(by_id["swift_adapter"][trace_id]), truth)
        for slot in sorted(python_base_odds):
            if slot not in swift_base_odds or slot not in swift_adapter_odds:
                continue
            base_errors.append(abs(python_base_odds[slot] - swift_base_odds[slot]))
            base_pairs.append((python_base_odds[slot], swift_base_odds[slot]))
            points.append((
                python_adapter_odds[slot] - python_base_odds[slot],
                swift_adapter_odds[slot] - swift_base_odds[slot],
            ))
        decode = (by_id["swift_base"][trace_id].get("inference") or {}).get("decode") or {}
        python_row = by_id["python_base"][trace_id]
        if (decode.get("prompt_tokens"), decode.get("image_tokens")) != (
            python_row["prompt_tokens"], python_row["image_tokens"]
        ):
            token_mismatches.append({
                "trace_id": trace_id,
                "swift": [decode.get("prompt_tokens"), decode.get("image_tokens")],
                "python": [python_row["prompt_tokens"], python_row["image_tokens"]],
            })
    informative = [(x, y) for x, y in points if abs(x) >= MINIMUM_EFFECT]
    denominator = sum(x * x for x, _ in informative)
    slope = sum(x * y for x, y in informative) / denominator if denominator else None
    return {
        "correlation": correlation(informative),
        "base_log_odds_slope": regression_slope(base_pairs),
        "boards": len(shared),
        "points": len(points),
        "informative_points": len(informative),
        "slope": slope,
        "base_log_odds_error_mean": sum(base_errors) / len(base_errors) if base_errors else None,
        "base_log_odds_error_max": max(base_errors) if base_errors else None,
        "token_mismatches": token_mismatches,
        # How Python computed the vision MLP: only "device" scores what the
        # app computes (common.match_device).
        "python_vision_gelu": sorted({
            str(row.get("vision_gelu", "unrecorded")) for row in [*python_base, *python_adapter]
        }),
    }


def correlation(points: list[tuple[float, float]]) -> float | None:
    """Pearson r of Swift's changes on Python's, or None with too few."""
    if len(points) < 3:
        return None
    mean_x = sum(x for x, _ in points) / len(points)
    mean_y = sum(y for _, y in points) / len(points)
    covariance = sum((x - mean_x) * (y - mean_y) for x, y in points)
    spread_x = math.sqrt(sum((x - mean_x) ** 2 for x, _ in points))
    spread_y = math.sqrt(sum((y - mean_y) ** 2 for _, y in points))
    return covariance / (spread_x * spread_y) if spread_x and spread_y else None


def regression_slope(points: list[tuple[float, float]]) -> float | None:
    """Ordinary least-squares slope of y on x, with an intercept."""
    if len(points) < 3:
        return None
    mean_x = sum(x for x, _ in points) / len(points)
    mean_y = sum(y for _, y in points) / len(points)
    spread = sum((x - mean_x) ** 2 for x, _ in points)
    return sum((x - mean_x) * (y - mean_y) for x, y in points) / spread if spread else None


def verdict(adapter: dict[str, object], canary: dict[str, object] | None) -> tuple[list[str], list[str]]:
    """(failures, notes) for one adapter and its doubled-scale canary."""
    failures, notes = [], []
    if adapter["token_mismatches"]:
        failures.append(f"{len(adapter['token_mismatches'])} boards differ in prompt or image tokens")
    if adapter["informative_points"] == 0 or adapter["slope"] is None:
        failures.append("the adapter changed nothing measurable, so parity proves nothing")
        return failures, notes
    r = adapter["correlation"]
    if r is None or r < MINIMUM_CORRELATION:
        failures.append(f"Swift's changes do not follow Python's (r={r}): not the same adapter")
    if canary is None or canary["slope"] is None:
        failures.append("no canary: a scale mix-up would go unseen")
    elif canary["slope"] / adapter["slope"] < MINIMUM_CANARY_RATIO:
        failures.append(
            f"the doubled-scale canary is not clearly stronger ({canary['slope']:.3f} against "
            f"{adapter['slope']:.3f}): the check cannot see a scale mix-up"
        )
    if adapter.get("python_vision_gelu", ["device"]) != ["device"]:
        notes.append(
            f"Python scored with vision GELU {adapter['python_vision_gelu']}, not the device's: "
            "the transfer slope compares two different models"
        )
    if not TRANSFER_RANGE[0] <= adapter["slope"] <= TRANSFER_RANGE[1]:
        notes.append(
            f"TRANSFER GAP: Swift shows {adapter['slope']:.3f} of Python's effect (base log-odds slope "
            f"{adapter['base_log_odds_slope']:.3f}); ADR 0019 needs [0.9, 1.1] before real training"
        )
    return failures, notes


def agrees(result: dict[str, object]) -> bool:
    """Whether the effects correlate and the token counts match: the
    plumbing half of `verdict`, without the canary."""
    r = result["correlation"]
    return (
        result["slope"] is not None and r is not None and r >= MINIMUM_CORRELATION
        and not result["token_mismatches"]
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--python-base", type=Path, required=True)
    parser.add_argument("--python-adapter", type=Path, required=True)
    parser.add_argument("--swift-base", type=Path, required=True)
    parser.add_argument("--swift-adapter", type=Path, required=True)
    parser.add_argument("--swift-canary", type=Path, required=True, help="a replay of the same adapter at twice its scale")
    parser.add_argument("--report", type=Path)
    arguments = parser.parse_args(argv)

    python_base, python_adapter = read_jsonl(arguments.python_base), read_jsonl(arguments.python_adapter)
    swift_base = read_jsonl(arguments.swift_base)
    report = {
        "adapter": compare(python_base, python_adapter, swift_base, read_jsonl(arguments.swift_adapter)),
        "canary": compare(python_base, python_adapter, swift_base, read_jsonl(arguments.swift_canary)),
    }
    failures, notes = verdict(report["adapter"], report["canary"])
    report["failures"], report["notes"] = failures, notes
    text = json.dumps(report, indent=2, sort_keys=True)
    print(text)
    if arguments.report:
        arguments.report.write_text(text + "\n")
    for note in notes:
        print(note)
    print("PARITY " + ("FAIL: " + "; ".join(failures) if failures else "PASS"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
