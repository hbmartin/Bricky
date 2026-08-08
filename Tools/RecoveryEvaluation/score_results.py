#!/usr/bin/env python3
"""Score triad benchmark NDJSON without model judging.

Rows carry an optional "kind": "recovery" (default, RecoveryBenchmarkV1),
"verification" (step-verifier verdicts), or "registration" (tracker fits).
Each kind has its own validation and release gates; a mixed file scores every
kind present and fails if any gate fails. The verification false-complete
rate is the headline number (ADR 0008): a wrong "complete" is the one
failure the product must not make.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
from pathlib import Path

MINIMUM_CORPUS_ROWS = 40
MINIMUM_AUTHORED_MODELS = 6

RECOVERY_REQUIRED_FIELDS = {
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
    "estimator_method",
    "device_model",
    "operating_system",
    "latency_ms",
    "memory_peak_bytes",
}

# Which pipeline produced an estimate (ADR 0010). Required, not inferred: this
# was previously sniffed from a `model_revision` prefix on a field the row
# schema never carried, so every row silently bucketed as composite and the
# geometric latency gate could not fire.
ESTIMATOR_METHODS = {"geometric", "composite", "vlm"}

RELEASE_FIELDS = {
    "physical_case",
    "authored_model_id",
    "legal_use_confirmed",
    "lighting_condition",
    "capture_angle",
    "occlusion_condition",
}

VERIFICATION_REQUIRED_FIELDS = {
    "schema_version",
    "fixture_id",
    "expected_verdict",
    "produced_verdict",
    "detectability",
    "latency_ms",
}
VERDICTS = {"complete", "incomplete", "misplaced", "uncertain"}
DETECTABILITY = {"strong", "marginal", "undetectable"}

REGISTRATION_REQUIRED_FIELDS = {
    "schema_version",
    "fixture_id",
    "converged",
    "translation_error_m",
    "yaw_error_degrees",
    "ambiguity_expected",
    "reported_ambiguous",
    "latency_ms",
}

# Gates.
RECOVERY_TOP3_FLOOR = 0.95
RECOVERY_TOP1_FLOOR = 0.80
RECOVERY_COMPOSITE_MEDIAN_MS = 20_000
RECOVERY_GEOMETRIC_MEDIAN_MS = 8_000
VERIFICATION_FALSE_COMPLETE_CEILING = 0.02
VERIFICATION_PRECISION_FLOOR = {"strong": 0.90, "marginal": 0.80}
VERIFICATION_RECALL_FLOOR = {"strong": 0.85, "marginal": 0.70}
VERIFICATION_ABSTENTION_FLOOR = 0.95
VERIFICATION_UNCERTAIN_ON_CORRECT_CEILING = 0.15
VERIFICATION_MEDIAN_MS = 3_000
REGISTRATION_CONVERGENCE_FLOOR = 0.95
REGISTRATION_TRANSLATION_RMSE_M = 0.003
REGISTRATION_YAW_RMSE_DEGREES = 2.0
REGISTRATION_AMBIGUITY_RECALL_FLOOR = 0.90


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


def is_number(value: object) -> bool:
    # NaN and infinities are not measurements: NaN silently poisons every
    # median and comparison it touches instead of failing a gate.
    if type(value) is int:
        return True
    return type(value) is float and math.isfinite(value)


def require_valid_latency(row: dict[str, object], label: str) -> None:
    latency = row["latency_ms"]
    if not (isinstance(latency, (int, float)) and is_number(latency) and latency >= 0):
        raise SystemExit(f"{label} latency_ms must be a finite non-negative number")


def rmse(values: list[float]) -> float:
    if not values:
        return 0.0
    return (sum(value * value for value in values) / len(values)) ** 0.5


def validate_minimum_corpus(rows: list[dict[str, object]], kind: str) -> None:
    if len(rows) < MINIMUM_CORPUS_ROWS:
        raise SystemExit(
            f"{kind} corpus has {len(rows)} rows but release gates require at least "
            f"{MINIMUM_CORPUS_ROWS}; pass --allow-small-corpus only for "
            "schema/scorer smoke data, never for release-gate metrics"
        )


# --- Recovery (RecoveryBenchmarkV1, kind absent or "recovery") ---------------


def validate_rows(rows: list[dict[str, object]]) -> None:
    for index, row in enumerate(rows, start=1):
        if row.get("schema_version") != 1:
            raise SystemExit(f"unsupported benchmark schema: {row.get('schema_version')}")
        missing = sorted(RECOVERY_REQUIRED_FIELDS - row.keys())
        if missing:
            raise SystemExit(f"row {index} missing fields: {', '.join(missing)}")
        if not isinstance(row["ranked_step_ids"], list):
            raise SystemExit(f"row {index} ranked_step_ids must be a list")
        if row["certainty"] not in {"high", "medium", "low", "insufficient"}:
            raise SystemExit(f"row {index} has invalid certainty")
        if row["estimator_method"] not in ESTIMATOR_METHODS:
            raise SystemExit(f"row {index} has invalid estimator_method")
        expected_index = row["expected_step_index"]
        if not is_exact_int(expected_index) or expected_index < -1:
            raise SystemExit(f"row {index} expected_step_index must be an integer >= -1")
        top_index = row.get("top_step_index")
        if row["certainty"] != "insufficient" and top_index is None:
            raise SystemExit(f"row {index} requires top_step_index unless certainty is insufficient")
        if top_index is not None and (not is_exact_int(top_index) or top_index < -1):
            raise SystemExit(f"row {index} top_step_index must be null or an integer >= -1")
        require_valid_latency(row, f"row {index}")


def step_index(step_id: object) -> int | None:
    if not isinstance(step_id, str) or "#" not in step_id:
        return None
    try:
        return int(step_id.rsplit("#", 1)[1])
    except ValueError:
        return None


def validate_release_corpus(rows: list[dict[str, object]]) -> None:
    fixtures: set[str] = set()
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
        fixture_id = row.get("fixture_id")
        if not isinstance(fixture_id, str) or not fixture_id.strip():
            raise SystemExit(f"release row {index} fixture_id must be a non-empty string")
        fixtures.add(fixture_id.strip())
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
    # Distinct fixtures, not raw rows: duplicated captures must not pad the
    # corpus past the release gate.
    if len(fixtures) < MINIMUM_CORPUS_ROWS:
        raise SystemExit(
            f"corpus has {len(fixtures)} distinct fixture IDs but release gates require "
            f"at least {MINIMUM_CORPUS_ROWS}; pass --allow-small-corpus only for "
            "schema/scorer smoke data, never for release-gate metrics"
        )
    if len(models) < MINIMUM_AUTHORED_MODELS:
        raise SystemExit(
            f"release corpus has {len(models)} authored models but requires at least "
            f"{MINIMUM_AUTHORED_MODELS}"
        )
    for field, values in variation.items():
        if len(values) < 2:
            raise SystemExit(f"release corpus needs at least two explicit {field} values")


def median_latency(rows: list[dict[str, object]]) -> float | None:
    if not rows:
        return None
    return statistics.median([float(row["latency_ms"]) for row in rows])


def score_recovery(rows: list[dict[str, object]], *, allow_small_corpus: bool) -> tuple[dict[str, object], bool]:
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
    by_method = {
        method: [row for row in rows if row["estimator_method"] == method]
        for method in ESTIMATOR_METHODS
    }
    latencies = [float(row["latency_ms"]) for row in rows]
    memory = [int(row.get("memory_peak_bytes", 0)) for row in rows]
    report: dict[str, object] = {
        "cases": len(rows),
        # Insufficient cases are not silently removed from accuracy gates.
        "top_1_accuracy": top1 / len(rows),
        "top_3_accuracy": top3 / len(rows),
        "insufficient_rate": (len(rows) - len(sufficient)) / len(rows),
        "adjacent_step_confusion_rate": adjacent / max(1, len(sufficient)),
        "geometric_cases": len(by_method["geometric"]),
        "composite_cases": len(by_method["composite"]),
        "vlm_cases": len(by_method["vlm"]),
        "geometric_median_latency_ms": median_latency(by_method["geometric"]),
        "composite_median_latency_ms": median_latency(by_method["composite"]),
        "vlm_median_latency_ms": median_latency(by_method["vlm"]),
        "median_latency_ms": statistics.median(latencies),
        "p95_latency_ms": percentile(latencies, 0.95),
        "memory_peak_bytes": max(memory),
    }
    # Each method is judged against its own budget. Both fallback methods take
    # the composite budget: they pay for inference either way, and a composite
    # row's latency already includes the geometric leg that stepped aside.
    failed = (
        report["top_3_accuracy"] < RECOVERY_TOP3_FLOOR
        or report["top_1_accuracy"] < RECOVERY_TOP1_FLOOR
        or (report["geometric_median_latency_ms"] or 0) > RECOVERY_GEOMETRIC_MEDIAN_MS
        or (report["composite_median_latency_ms"] or 0) > RECOVERY_COMPOSITE_MEDIAN_MS
        or (report["vlm_median_latency_ms"] or 0) > RECOVERY_COMPOSITE_MEDIAN_MS
    )
    return report, failed


# --- Verification (kind == "verification") -----------------------------------


def validate_verification_rows(rows: list[dict[str, object]]) -> None:
    for index, row in enumerate(rows, start=1):
        if row.get("schema_version") != 1:
            raise SystemExit(f"verification row {index} has unsupported schema")
        missing = sorted(VERIFICATION_REQUIRED_FIELDS - row.keys())
        if missing:
            raise SystemExit(f"verification row {index} missing fields: {', '.join(missing)}")
        if row["expected_verdict"] not in VERDICTS or row["produced_verdict"] not in VERDICTS:
            raise SystemExit(f"verification row {index} has an invalid verdict")
        if row["detectability"] not in DETECTABILITY:
            raise SystemExit(f"verification row {index} has invalid detectability")
        require_valid_latency(row, f"verification row {index}")


def score_verification(rows: list[dict[str, object]], *, allow_small_corpus: bool) -> tuple[dict[str, object], bool]:
    validate_verification_rows(rows)
    if not allow_small_corpus:
        validate_minimum_corpus(rows, "verification")
    discriminable = [row for row in rows if row["detectability"] in {"strong", "marginal"}]
    negatives = [row for row in discriminable if row["expected_verdict"] != "complete"]
    false_completes = [row for row in negatives if row["produced_verdict"] == "complete"]
    false_complete_rate = len(false_completes) / len(negatives) if negatives else 0.0

    per_class: dict[str, dict[str, object]] = {}
    class_failures = False
    for detectability in ("strong", "marginal"):
        in_class = [row for row in discriminable if row["detectability"] == detectability]
        true_positive = sum(
            row["expected_verdict"] == "complete" and row["produced_verdict"] == "complete"
            for row in in_class
        )
        false_positive = sum(
            row["expected_verdict"] != "complete" and row["produced_verdict"] == "complete"
            for row in in_class
        )
        expected_complete = sum(row["expected_verdict"] == "complete" for row in in_class)
        precision = true_positive / (true_positive + false_positive) if (true_positive + false_positive) else None
        recall = true_positive / expected_complete if expected_complete else None
        per_class[detectability] = {"complete_precision": precision, "complete_recall": recall, "cases": len(in_class)}
        if precision is not None and precision < VERIFICATION_PRECISION_FLOOR[detectability]:
            class_failures = True
        if recall is not None and recall < VERIFICATION_RECALL_FLOOR[detectability]:
            class_failures = True

    undetectable = [row for row in rows if row["detectability"] == "undetectable"]
    abstained = sum(row["produced_verdict"] == "uncertain" for row in undetectable)
    abstention_rate = abstained / len(undetectable) if undetectable else None

    correct_strong = [
        row for row in rows
        if row["detectability"] == "strong" and row["expected_verdict"] == "complete"
    ]
    uncertain_on_correct = (
        sum(row["produced_verdict"] == "uncertain" for row in correct_strong) / len(correct_strong)
        if correct_strong else None
    )

    latencies = [float(row["latency_ms"]) for row in rows]
    report: dict[str, object] = {
        "false_complete_rate": false_complete_rate,
        "false_complete_cases": len(false_completes),
        "per_detectability": per_class,
        "undetectable_abstention_rate": abstention_rate,
        "uncertain_on_correct_rate": uncertain_on_correct,
        "median_latency_ms": statistics.median(latencies) if latencies else None,
        "cases": len(rows),
    }
    failed = (
        false_complete_rate > VERIFICATION_FALSE_COMPLETE_CEILING
        or class_failures
        or (abstention_rate is not None and abstention_rate < VERIFICATION_ABSTENTION_FLOOR)
        or (uncertain_on_correct is not None and uncertain_on_correct > VERIFICATION_UNCERTAIN_ON_CORRECT_CEILING)
        or (latencies and statistics.median(latencies) > VERIFICATION_MEDIAN_MS)
    )
    return report, failed


# --- Registration (kind == "registration") -----------------------------------


def validate_registration_rows(rows: list[dict[str, object]]) -> None:
    for index, row in enumerate(rows, start=1):
        if row.get("schema_version") != 1:
            raise SystemExit(f"registration row {index} has unsupported schema")
        missing = sorted(REGISTRATION_REQUIRED_FIELDS - row.keys())
        if missing:
            raise SystemExit(f"registration row {index} missing fields: {', '.join(missing)}")
        for flag in ("converged", "ambiguity_expected", "reported_ambiguous"):
            if not isinstance(row[flag], bool):
                raise SystemExit(f"registration row {index} {flag} must be a boolean")
        for field in ("translation_error_m", "yaw_error_degrees"):
            if not is_number(row[field]):
                raise SystemExit(f"registration row {index} {field} must be a finite number")
        require_valid_latency(row, f"registration row {index}")


def score_registration(rows: list[dict[str, object]], *, allow_small_corpus: bool) -> tuple[dict[str, object], bool]:
    validate_registration_rows(rows)
    if not allow_small_corpus:
        validate_minimum_corpus(rows, "registration")
    # A genuinely symmetric fixture cannot converge to a unique truth; it is
    # judged on reporting ambiguity, not on convergence.
    unambiguous = [row for row in rows if not row["ambiguity_expected"]]
    converged = [row for row in unambiguous if row["converged"]]
    convergence_rate = len(converged) / len(unambiguous) if unambiguous else None
    translation_rmse = rmse([float(row["translation_error_m"]) for row in converged])
    yaw_rmse = rmse([float(row["yaw_error_degrees"]) for row in converged])
    ambiguous_expected = [row for row in rows if row["ambiguity_expected"]]
    ambiguity_recall = (
        sum(row["reported_ambiguous"] for row in ambiguous_expected) / len(ambiguous_expected)
        if ambiguous_expected else None
    )
    report: dict[str, object] = {
        "cases": len(rows),
        "convergence_rate": convergence_rate,
        "translation_rmse_m": translation_rmse if converged else None,
        "yaw_rmse_degrees": yaw_rmse if converged else None,
        "ambiguity_recall": ambiguity_recall,
    }
    failed = (
        (convergence_rate is not None and convergence_rate < REGISTRATION_CONVERGENCE_FLOOR)
        or (converged and translation_rmse > REGISTRATION_TRANSLATION_RMSE_M)
        or (converged and yaw_rmse > REGISTRATION_YAW_RMSE_DEGREES)
        or (ambiguity_recall is not None and ambiguity_recall < REGISTRATION_AMBIGUITY_RECALL_FLOOR)
    )
    return report, failed


# --- Entry -------------------------------------------------------------------


def partition(rows: list[dict[str, object]]) -> dict[str, list[dict[str, object]]]:
    kinds: dict[str, list[dict[str, object]]] = {"recovery": [], "verification": [], "registration": []}
    for index, row in enumerate(rows, start=1):
        kind = row.get("kind", "recovery")
        if kind not in kinds:
            raise SystemExit(f"row {index} has unknown kind: {kind}")
        kinds[kind].append(row)
    return kinds


def main(path: Path, *, allow_small_corpus: bool = False) -> None:
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows:
        raise SystemExit("no benchmark rows")
    kinds = partition(rows)
    report: dict[str, object] = {}
    failed = False
    if kinds["verification"]:
        verification_report, verification_failed = score_verification(kinds["verification"], allow_small_corpus=allow_small_corpus)
        # The headline number, printed before anything else (ADR 0008).
        print(f"FALSE_COMPLETE_RATE {verification_report['false_complete_rate']:.4f}")
        report["verification"] = verification_report
        failed = failed or verification_failed
    if kinds["registration"]:
        registration_report, registration_failed = score_registration(kinds["registration"], allow_small_corpus=allow_small_corpus)
        report["registration"] = registration_report
        failed = failed or registration_failed
    if kinds["recovery"]:
        recovery_report, recovery_failed = score_recovery(kinds["recovery"], allow_small_corpus=allow_small_corpus)
        report["recovery"] = recovery_report
        failed = failed or recovery_failed
    print(json.dumps(report, indent=2, sort_keys=True))
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path, metavar="DEVICE_RESULTS.ndjson")
    parser.add_argument(
        "--allow-small-corpus",
        action="store_true",
        help=f"permit fewer than {MINIMUM_CORPUS_ROWS} rows per kind (smoke fixtures only)",
    )
    arguments = parser.parse_args()
    main(arguments.results, allow_small_corpus=arguments.allow_small_corpus)
