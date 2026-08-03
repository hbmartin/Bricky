#!/usr/bin/env python3
"""Score RecoveryBenchmarkV1 device-result NDJSON without model judging."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

MINIMUM_CORPUS_ROWS = 150
MINIMUM_AUTHORED_MODELS = 10

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
    "ranked_step_ids",
    "certainty",
    "device_model",
    "operating_system",
    "latency_ms",
    "memory_peak_bytes",
}

RELEASE_FIELDS = {
    "physical_case",
    "authored_model_id",
    "legal_use_confirmed",
    "lighting_condition",
    "capture_angle",
    "occlusion_condition",
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


def is_exact_int(value: object) -> bool:
    return type(value) is int


def validate_rows(rows: list[dict[str, object]]) -> None:
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
        expected_index = row["expected_step_index"]
        if not is_exact_int(expected_index) or expected_index < -1:
            raise SystemExit(f"row {index} expected_step_index must be an integer >= -1")
        top_index = row.get("top_step_index")
        if row["certainty"] != "insufficient" and top_index is None:
            raise SystemExit(f"row {index} requires top_step_index unless certainty is insufficient")
        if top_index is not None and (not is_exact_int(top_index) or top_index < -1):
            raise SystemExit(f"row {index} top_step_index must be null or an integer >= -1")


def step_index(step_id: object) -> int | None:
    if not isinstance(step_id, str) or "#" not in step_id:
        return None
    try:
        return int(step_id.rsplit("#", 1)[1])
    except ValueError:
        return None


def validate_release_corpus(rows: list[dict[str, object]]) -> None:
    if len(rows) < MINIMUM_CORPUS_ROWS:
        raise SystemExit(
            f"corpus has {len(rows)} rows but release gates require at least "
            f"{MINIMUM_CORPUS_ROWS}; pass --allow-small-corpus only for schema/scorer "
            "smoke data, never for release-gate metrics"
        )
    models: set[str] = set()
    variation: dict[str, set[str]] = {
        "lighting_condition": set(),
        "capture_angle": set(),
        "occlusion_condition": set(),
    }
    for index, row in enumerate(rows, start=1):
        missing = sorted(RELEASE_FIELDS - row.keys())
        if missing:
            raise SystemExit(f"release row {index} missing fields: {', '.join(missing)}")
        if row["physical_case"] is not True:
            raise SystemExit(f"release row {index} is not explicitly marked as a physical case")
        if row["legal_use_confirmed"] is not True:
            raise SystemExit(f"release row {index} lacks confirmed legal-use provenance")
        model_id = row["authored_model_id"]
        if not isinstance(model_id, str) or not model_id.strip():
            raise SystemExit(f"release row {index} authored_model_id must be non-empty")
        models.add(model_id.strip())
        for field, values in variation.items():
            value = row[field]
            if not isinstance(value, str) or not value.strip():
                raise SystemExit(f"release row {index} {field} must be non-empty")
            values.add(value.strip().casefold())
        slots = row.get("candidate_slots")
        expected = row["expected_step_index"]
        if not isinstance(slots, dict) or not any(
            (candidate := step_index(step_id)) is not None and abs(candidate - expected) == 1
            for step_id in slots.values()
        ):
            raise SystemExit(f"release row {index} has no explicitly represented adjacent-step candidate")
    if len(models) < MINIMUM_AUTHORED_MODELS:
        raise SystemExit(
            f"release corpus has {len(models)} authored models but requires at least "
            f"{MINIMUM_AUTHORED_MODELS}"
        )
    for field, values in variation.items():
        if len(values) < 2:
            raise SystemExit(f"release corpus needs at least two explicit {field} values")


def main(path: Path, *, allow_small_corpus: bool = False) -> None:
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows:
        raise SystemExit("no benchmark rows")
    validate_rows(rows)
    if not allow_small_corpus:
        validate_release_corpus(rows)
    sufficient = [row for row in rows if row.get("certainty") != "insufficient"]
    top1 = sum(bool(row["ranked_step_ids"]) and row["ranked_step_ids"][0] == row["expected_step_id"] for row in sufficient)
    top3 = sum(row["expected_step_id"] in row.get("ranked_step_ids", [])[:3] for row in sufficient)
    adjacent = sum(
        abs(row["top_step_index"] - row["expected_step_index"]) == 1
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
