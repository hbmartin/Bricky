#!/usr/bin/env python3
"""Score RecoveryBenchmarkV1 device-result NDJSON without model judging."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

MINIMUM_CORPUS_ROWS = 150

REQUIRED_FIELDS = {
    "schema_version",
    "fixture_id",
    "instruction_sha256",
    "pyldraw3_version",
    "part_pack_version",
    "expected_step_id",
    "candidate_slots",
    "board_relative_paths",
    "camera_metadata",
    "expected_step_index",
    "top_step_index",
    "ranked_step_ids",
    "certainty",
    "device_model",
    "operating_system",
    "latency_ms",
    "memory_peak_bytes",
}


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def main(path: Path, allow_small_corpus: bool = False) -> None:
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows:
        raise SystemExit("no benchmark rows")
    if len(rows) < MINIMUM_CORPUS_ROWS and not allow_small_corpus:
        raise SystemExit(
            f"corpus has {len(rows)} rows but release gates require at least "
            f"{MINIMUM_CORPUS_ROWS}; pass --allow-small-corpus only for schema/scorer "
            "smoke data, never for release-gate metrics"
        )
    for index, row in enumerate(rows, start=1):
        if row.get("schema_version") != 1:
            raise SystemExit(f"unsupported benchmark schema: {row.get('schema_version')}")
        missing = sorted(REQUIRED_FIELDS - row.keys())
        if missing:
            raise SystemExit(f"row {index} missing fields: {', '.join(missing)}")
        if not isinstance(row["ranked_step_ids"], list):
            raise SystemExit(f"row {index} ranked_step_ids must be a list")
        if row["certainty"] not in {"high", "medium", "low", "insufficient"}:
            raise SystemExit(f"row {index} has invalid certainty")
    sufficient = [row for row in rows if row.get("certainty") != "insufficient"]
    top1 = sum(bool(row["ranked_step_ids"]) and row["ranked_step_ids"][0] == row["expected_step_id"] for row in sufficient)
    top3 = sum(row["expected_step_id"] in row.get("ranked_step_ids", [])[:3] for row in sufficient)
    adjacent = sum(
        abs(int(row.get("top_step_index", -10_000)) - int(row["expected_step_index"])) == 1
        for row in sufficient
    )
    latencies = [float(row["latency_ms"]) for row in rows]
    memory = [int(row.get("memory_peak_bytes", 0)) for row in rows]
    report = {
        "cases": len(rows),
        # Insufficient cases are not silently removed from accuracy gates.
        "top_1_accuracy": top1 / len(rows),
        "top_3_accuracy": top3 / len(rows),
        "insufficient_rate": (len(rows) - len(sufficient)) / len(rows),
        "adjacent_step_confusion_rate": adjacent / max(1, len(sufficient)),
        "median_latency_ms": statistics.median(latencies),
        "p95_latency_ms": percentile(latencies, 0.95),
        "memory_peak_bytes": max(memory),
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    failed = report["top_3_accuracy"] < 0.95 or report["top_1_accuracy"] < 0.80 or report["median_latency_ms"] > 20_000
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path, metavar="DEVICE_RESULTS.ndjson")
    parser.add_argument(
        "--allow-small-corpus",
        action="store_true",
        help=f"permit fewer than {MINIMUM_CORPUS_ROWS} rows (smoke fixtures only)",
    )
    arguments = parser.parse_args()
    main(arguments.results, allow_small_corpus=arguments.allow_small_corpus)
