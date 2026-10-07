#!/usr/bin/env python3
"""Check that Python and Swift agree on what an adapter does (ADR 0019).

    python3 parity_check.py --python-base base.jsonl --python-adapter adapted.jsonl \\
        --swift-base base.ndjson.traces.ndjson --swift-adapter adapted.ndjson.traces.ndjson \\
        [--swift-canary canary.ndjson.traces.ndjson]

Inputs are eval_first_slot.py outputs and `bricky-harness replay --scoring
probe` trace sidecars of the same boards. The two runtimes do not share a
build of MLX, so raw probabilities differ a little; what must agree is the
change the adapter makes. For every board and every slot other than the
truth, the change in log-odds against the truth slot is computed on each
side; the least-squares slope of Swift's change on Python's must lie in
[0.9, 1.1]. Log-odds between slot letters do not depend on how either side
normalises. A canary adapter written at twice the scale must fail the same
check: that is what shows the check would catch a 10-against-20 scale
mix-up. Prompt and image token counts must match exactly. Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

SLOPE_RANGE = (0.9, 1.1)
# Changes smaller than this (in nats) carry no slope information.
MINIMUM_EFFECT = 0.05


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
    points, base_errors, token_mismatches = [], [], []
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
        "boards": len(shared),
        "points": len(points),
        "informative_points": len(informative),
        "slope": slope,
        "base_log_odds_error_mean": sum(base_errors) / len(base_errors) if base_errors else None,
        "base_log_odds_error_max": max(base_errors) if base_errors else None,
        "token_mismatches": token_mismatches,
    }


def agrees(result: dict[str, object]) -> bool:
    slope = result["slope"]
    return slope is not None and SLOPE_RANGE[0] <= slope <= SLOPE_RANGE[1] and not result["token_mismatches"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--python-base", type=Path, required=True)
    parser.add_argument("--python-adapter", type=Path, required=True)
    parser.add_argument("--swift-base", type=Path, required=True)
    parser.add_argument("--swift-adapter", type=Path, required=True)
    parser.add_argument("--swift-canary", type=Path, help="a replay of the same adapter at twice its scale")
    parser.add_argument("--report", type=Path)
    arguments = parser.parse_args(argv)

    python_base, python_adapter = read_jsonl(arguments.python_base), read_jsonl(arguments.python_adapter)
    swift_base = read_jsonl(arguments.swift_base)
    report = {"adapter": compare(python_base, python_adapter, swift_base, read_jsonl(arguments.swift_adapter))}
    failures = []
    if not agrees(report["adapter"]):
        failures.append("the adapter's effect differs between Python and Swift")
    if report["adapter"]["informative_points"] == 0:
        failures.append("the adapter changed nothing measurable, so parity proves nothing")
    if arguments.swift_canary:
        report["canary"] = compare(python_base, python_adapter, swift_base, read_jsonl(arguments.swift_canary))
        if agrees(report["canary"]):
            failures.append("the doubled-scale canary passed: the check cannot see a scale mix-up")
    report["failures"] = failures
    text = json.dumps(report, indent=2, sort_keys=True)
    print(text)
    if arguments.report:
        arguments.report.write_text(text + "\n")
    print("PARITY " + ("FAIL: " + "; ".join(failures) if failures else "PASS"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
