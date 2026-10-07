#!/usr/bin/env python3
"""Score triad benchmark NDJSON without model judging.

Rows carry an optional "kind": "recovery" (default, RecoveryBenchmarkV1),
"verification" (step-verifier verdicts), or "registration" (tracker fits).
Each kind has its own validation and gates; a mixed file scores every kind
present. The verification false-complete rate is the headline number
(ADR 0008): a wrong "complete" is the one failure the product must not make.

Unmeasured is not zero. A gate whose denominator is empty is UNMEASURED,
never a perfect score. In release mode (the default) every rate gate is
judged on a one-sided 95% Clopper-Pearson bound and every median-latency gate
on a distribution-free order-statistic bound, so the sample size a gate needs
follows from the arithmetic (`--explain-minimums`) instead of a fixed row
count; a required gate or kind that is UNMEASURED fails the run. The
informational mode (`--informational`, formerly `--allow-small-corpus`)
judges point estimates and only reports UNMEASURED gates.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
from dataclasses import dataclass
from pathlib import Path

# PENDING owner decision (2026-09-25): whether the recovery release corpus
# must span 6 or 10 authored models. Kept at the historical value until then.
MINIMUM_AUTHORED_MODELS = 6

# The device floor (ADR 0012 amendment): iPhone 17 Pro / Pro Max, whose
# identifiers are iPhone18,1 and iPhone18,2. Release rows must come from an
# admitted device; `replay:<mac>` rows, Macs, iPads, and older phones are not
# device evidence.
MINIMUM_IPHONE_FAMILY = 18
DEVICE_MODEL_PATTERN = re.compile(r"^iPhone(\d+),\d+$")
CAPTURE_ANGLES = {"left", "center", "right"}
# Fields that mark a row as deliberately not release evidence: challenge-set
# rows and rows expected to fail by construction.
NON_RELEASE_FIELDS = ("expected_failure", "challenge_class")

CONFIDENCE = 0.95
# Below this many converged fits an RMSE is an anecdote, not a measurement.
MINIMUM_RMSE_SAMPLES = 20
KINDS = ("recovery", "verification", "registration")
# Row kinds that describe how a corpus was generated rather than measuring
# anything. They pass through to the report (and to check_regression, which
# guards their counts) but are never scored and never release evidence.
SUMMARY_KINDS = ("synthetic_summary",)
# Challenge-set rows: mistake classes the regression taxonomy lacks, some of
# them unsolvable by depth alone. Reported per class, never gated, never
# release evidence.
CHALLENGE_KIND = "verification_challenge"
# Replayed VLM step checks (bricky-harness replay --checks): the VLM check's
# false-complete rate, reported beside the geometric verifier's. Mac replay
# rows, so never release evidence.
VLM_CHECK_KIND = "vlm_check"
# The Foundation Models advisor beside photo checks, in shadow (ADR 0018).
SHADOW_CHECK_KIND = "shadow_check"
# One verification window's lattice evidence (bricky-harness lattice-rows,
# iOS 27 Phase 4): read for the stud-keypoint entry criterion (ADR 0020),
# never a release gate.
LATTICE_WINDOW_KIND = "lattice_window"
# The entry rule: enough staged device windows from enough sessions, and a
# one-sided 95% bound on the lattice-trouble rate on one side of 5%.
LATTICE_ENTRY_MINIMUM_WINDOWS = 30
LATTICE_ENTRY_MINIMUM_SESSIONS = 3
LATTICE_ENTRY_RATE = 0.05
LATTICE_ENTRY_SCENARIOS = {"complete", "shifted_one_stud"}
# Per-placement build diff rows (M2.3): what the shadow diff concluded about
# each authored placement. Informational until real windows exist.
PLACEMENT_KIND = "placement"
PLACEMENT_STATES = {"present", "absent", "displaced", "rotated", "colour_mismatch", "not_observable"}
PLACEMENT_FALSE_PRESENT_CEILING = 0.02
# Synthetic repair plans (M2.4): deterministic actions from a verdict. A
# harmful action (one that would make the build worse) must never happen.
REPAIR_KIND = "repair_plan"
# Synthetic geometric recovery (M2.6): the real estimator on rendered,
# degraded scenes, including steps built short of a part. Never release
# evidence: device recovery rows are kind "recovery".
GEOMETRIC_RECOVERY_KIND = "geometric_recovery"
# Suggested ghost placements (M2.7): a wrong proposal is the failure; not
# proposing is always allowed. The gate is on proposals made.
PLACEMENT_SUGGESTION_KIND = "placement_suggestion"
WRONG_PROPOSAL_CEILING = 0.05

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
    "capture_elevation_degrees",
}

# Viewing-elevation bands a release corpus must span at least two of. The
# edges are RECONSTRUCTED (a judgment about "low", "typical tabletop", and
# "overhead" views), not measured; revisit with the first physical corpus.
ELEVATION_BAND_EDGES = (35.0, 60.0)

VERIFICATION_REQUIRED_FIELDS = {
    "schema_version",
    "fixture_id",
    "expected_verdict",
    "produced_verdict",
    "detectability",
    "latency_ms",
}
VERDICTS = {"complete", "incomplete", "misplaced", "uncertain"}
# What a photo step check may answer. Mirrors CheckVerdictV1 in
# RecoveryEvidenceKit/VerdictSchemasV1.swift; a test holds the two equal.
CHECK_VERDICTS = {"complete", "incomplete", "uncertain"}
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


def rmse(values: list[float]) -> float | None:
    if not values:
        return None
    return (sum(value * value for value in values) / len(values)) ** 0.5


# --- Confidence bounds (stdlib only: CI runs plain python3) ------------------


def binomial_cdf(k: int, n: int, p: float) -> float:
    """P(X <= k) for X ~ Binomial(n, p), summed in log space."""
    if k < 0:
        return 0.0
    if k >= n:
        return 1.0
    if p <= 0.0:
        return 1.0
    if p >= 1.0:
        return 0.0
    log_p, log_q = math.log(p), math.log1p(-p)
    log_n_factorial = math.lgamma(n + 1)
    total = 0.0
    for i in range(k + 1):
        log_term = (
            log_n_factorial - math.lgamma(i + 1) - math.lgamma(n - i + 1)
            + i * log_p + (n - i) * log_q
        )
        total += math.exp(log_term)
    return min(total, 1.0)


def _bisect(predicate, low: float = 0.0, high: float = 1.0) -> float:
    """Smallest p in [low, high] for which the monotone predicate holds."""
    for _ in range(100):
        middle = (low + high) / 2
        if predicate(middle):
            high = middle
        else:
            low = middle
    return high


def clopper_pearson_upper(events: int, trials: int, confidence: float = CONFIDENCE) -> float | None:
    """One-sided upper confidence bound on a rate. None without trials."""
    if trials <= 0:
        return None
    if events >= trials:
        return 1.0
    alpha = 1.0 - confidence
    if events == 0:
        return 1.0 - alpha ** (1.0 / trials)
    return _bisect(lambda p: binomial_cdf(events, trials, p) <= alpha)


def clopper_pearson_lower(events: int, trials: int, confidence: float = CONFIDENCE) -> float | None:
    """One-sided lower confidence bound on a rate. None without trials."""
    if trials <= 0:
        return None
    upper_of_misses = clopper_pearson_upper(trials - events, trials, confidence)
    return None if upper_of_misses is None else 1.0 - upper_of_misses


def median_upper_bound(values: list[float], confidence: float = CONFIDENCE) -> float | None:
    """Distribution-free upper confidence bound on the median: the smallest
    order statistic X(k) with P(X(k) >= median) >= confidence. None when the
    sample is too small for any order statistic to qualify (n < 5 at 95%)."""
    ordered = sorted(values)
    n = len(ordered)
    for k in range(1, n + 1):
        if binomial_cdf(k - 1, n, 0.5) >= confidence:
            return ordered[k - 1]
    return None


# --- Gates -------------------------------------------------------------------

PASS, FAIL, UNMEASURED, DORMANT = "PASS", "FAIL", "UNMEASURED", "DORMANT"


@dataclass(frozen=True)
class Gate:
    """One release gate. `value` is the point estimate; `bound` is the
    conservative figure release mode judges (a confidence bound, or the
    value itself for counts and sufficiently sampled RMSEs)."""

    name: str
    comparator: str  # "min": judged >= threshold; "max": judged <= threshold
    threshold: float
    value: float | None
    bound: float | None
    trials: int
    events: int | None = None
    required: bool = True
    dormant: bool = False

    def status(self, *, release: bool) -> str:
        if self.dormant:
            return DORMANT
        judged = self.bound if release else self.value
        if judged is None:
            return UNMEASURED
        passed = judged >= self.threshold if self.comparator == "min" else judged <= self.threshold
        return PASS if passed else FAIL

    def fails(self, *, release: bool) -> bool:
        status = self.status(release=release)
        return status == FAIL or (release and status == UNMEASURED and self.required)

    def summary(self, *, release: bool) -> dict[str, object]:
        return {
            "status": self.status(release=release),
            "value": self.value,
            "bound": self.bound,
            "events": self.events,
            "trials": self.trials,
            "threshold": self.threshold,
            "comparator": self.comparator,
            "required": self.required,
        }


def rate_gate(
    name: str,
    events: int,
    trials: int,
    *,
    floor: float | None = None,
    ceiling: float | None = None,
    required: bool = True,
    dormant: bool = False,
) -> Gate:
    value = events / trials if trials else None
    if floor is not None:
        return Gate(name, "min", floor, value, clopper_pearson_lower(events, trials), trials, events, required, dormant)
    assert ceiling is not None
    return Gate(name, "max", ceiling, value, clopper_pearson_upper(events, trials), trials, events, required, dormant)


def median_gate(name: str, latencies: list[float], ceiling: float, *, required: bool = True) -> Gate:
    value = statistics.median(latencies) if latencies else None
    return Gate(name, "max", ceiling, value, median_upper_bound(latencies), len(latencies), None, required)


def rmse_gate(name: str, errors: list[float], ceiling: float) -> Gate:
    value = rmse(errors)
    bound = value if len(errors) >= MINIMUM_RMSE_SAMPLES else None
    return Gate(name, "max", ceiling, value, bound, len(errors))


def count_gate(name: str, count: int, ceiling: int, *, trials: int) -> Gate:
    """A hard count limit over `trials` rows, judged identically in both modes."""
    return Gate(name, "max", ceiling, count, count, trials, count)


def evaluate(gates: list[Gate], *, release: bool) -> bool:
    return any(gate.fails(release=release) for gate in gates)


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


def validate_release_device(row: dict[str, object], label: str) -> None:
    """A release row must come from an admitted physical device. This is what
    keeps `replay:<mac>` rows — which copy the staged declaration's physical
    and legal-use flags verbatim — out of release evidence."""
    device_model = row.get("device_model")
    match = DEVICE_MODEL_PATTERN.match(device_model) if isinstance(device_model, str) else None
    if match is None:
        raise SystemExit(f"{label} device_model {device_model!r} is not a physical iPhone identifier")
    if int(match.group(1)) < MINIMUM_IPHONE_FAMILY:
        raise SystemExit(
            f"{label} device_model {device_model!r} is below the device floor "
            f"(iPhone{MINIMUM_IPHONE_FAMILY},x)"
        )
    for field in NON_RELEASE_FIELDS:
        if field in row:
            raise SystemExit(f"{label} carries {field!r} and is not release evidence")


def unique_fixture(row: dict[str, object], fixtures: set[str], label: str) -> None:
    fixture_id = row.get("fixture_id")
    if not isinstance(fixture_id, str) or not fixture_id.strip():
        raise SystemExit(f"{label} fixture_id must be a non-empty string")
    # One row per fixture: a repeated capture — or a device row and its own
    # Mac replay, which share the session UUID — would otherwise pad every
    # bound's sample size with correlated evidence.
    if fixture_id.strip() in fixtures:
        raise SystemExit(f"{label} repeats fixture_id {fixture_id.strip()!r}")
    fixtures.add(fixture_id.strip())


def validate_capture_angles(value: object, label: str) -> None:
    """`capture_angle` names the set of views a session captured, joined by
    commas; every full session is "left,center,right". The recovery flow needs
    the center view and at least one side view."""
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"{label} capture_angle must be non-empty")
    angles = [angle.strip().casefold() for angle in value.split(",") if angle.strip()]
    unknown = sorted(set(angles) - CAPTURE_ANGLES)
    if unknown:
        raise SystemExit(f"{label} capture_angle has unknown views: {', '.join(unknown)}")
    if len(set(angles)) != len(angles):
        raise SystemExit(f"{label} capture_angle repeats a view")
    if "center" not in angles or len(angles) < 2:
        raise SystemExit(f"{label} capture_angle needs the center view and at least one side view")


def elevation_band(value: object, label: str) -> str:
    if not is_number(value) or not -90 <= float(value) <= 90:
        raise SystemExit(f"{label} capture_elevation_degrees must be a finite angle in [-90, 90]")
    low, high = ELEVATION_BAND_EDGES
    return "low" if float(value) < low else ("mid" if float(value) <= high else "high")


def validate_release_corpus(rows: list[dict[str, object]]) -> None:
    """Provenance preflight for release mode. It checks what the rows are,
    not how many there are: sample size is judged per gate by its bound."""
    fixtures: set[str] = set()
    models: set[str] = set()
    # Corpus-level variety. Capture angle is not here: every session captures
    # the same three views, so a per-corpus "two distinct values" rule on it
    # could never pass on real data. Viewing variety is the measured
    # elevation instead, banded.
    variation: dict[str, set[str]] = {
        "lighting_condition": set(),
        "occlusion_condition": set(),
    }
    elevation_bands: set[str] = set()
    for index, row in enumerate(rows, start=1):
        label = f"release row {index}"
        missing = sorted(RELEASE_FIELDS - row.keys())
        if missing:
            raise SystemExit(f"{label} missing fields: {', '.join(missing)}")
        unique_fixture(row, fixtures, label)
        validate_release_device(row, label)
        validate_capture_angles(row["capture_angle"], label)
        elevation_bands.add(elevation_band(row["capture_elevation_degrees"], label))
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
    if len(elevation_bands) < 2:
        raise SystemExit(
            "release corpus needs captures in at least two viewing-elevation bands "
            f"(edges {ELEVATION_BAND_EDGES[0]:g}° and {ELEVATION_BAND_EDGES[1]:g}°); "
            f"found {', '.join(sorted(elevation_bands))}"
        )


def median_latency(rows: list[dict[str, object]]) -> float | None:
    if not rows:
        return None
    return statistics.median([float(row["latency_ms"]) for row in rows])


def score_recovery(rows: list[dict[str, object]], *, release: bool) -> tuple[dict[str, object], list[Gate]]:
    validate_rows(rows)
    if release:
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
    # The benchmark protocol's buckets (roadmap §4.5): gates move to the
    # sustained bucket once device rows exist; until then they are reported.
    by_bucket: dict[str, list[float]] = {}
    for row in rows:
        by_bucket.setdefault(str(row.get("latency_bucket") or "unbucketed"), []).append(float(row["latency_ms"]))
    report: dict[str, object] = {
        "cases": len(rows),
        # Insufficient cases are not silently removed from accuracy gates.
        "top_1_accuracy": top1 / len(rows),
        "top_3_accuracy": top3 / len(rows),
        "insufficient_rate": (len(rows) - len(sufficient)) / len(rows),
        "adjacent_step_confusion_rate": adjacent / len(sufficient) if sufficient else None,
        "geometric_cases": len(by_method["geometric"]),
        "composite_cases": len(by_method["composite"]),
        "vlm_cases": len(by_method["vlm"]),
        "geometric_median_latency_ms": median_latency(by_method["geometric"]),
        "composite_median_latency_ms": median_latency(by_method["composite"]),
        "vlm_median_latency_ms": median_latency(by_method["vlm"]),
        "median_latency_ms": statistics.median(latencies),
        "p95_latency_ms": percentile(latencies, 0.95),
        "memory_peak_bytes": max(memory),
        "latency_by_bucket": {
            bucket: {
                "cases": len(values),
                "p50_ms": statistics.median(values),
                "p95_ms": percentile(values, 0.95),
            }
            for bucket, values in sorted(by_bucket.items())
        },
    }
    # Each method is judged against its own budget. Both fallback methods take
    # the composite budget: they pay for inference either way, and a composite
    # row's latency already includes the geometric leg that stepped aside. An
    # empty bucket is unmeasured, never "0 ms": geometric recovery is the
    # primary path and composite the fallback a release must have exercised,
    # so both are required; a VLM-only row has no geometric leg and is judged
    # only when present.
    def bucket_latencies(method: str) -> list[float]:
        return [float(row["latency_ms"]) for row in by_method[method]]

    gates = [
        rate_gate("recovery.top_3_accuracy", top3, len(rows), floor=RECOVERY_TOP3_FLOOR),
        rate_gate("recovery.top_1_accuracy", top1, len(rows), floor=RECOVERY_TOP1_FLOOR),
        median_gate("recovery.geometric_median_latency_ms", bucket_latencies("geometric"), RECOVERY_GEOMETRIC_MEDIAN_MS),
        median_gate("recovery.composite_median_latency_ms", bucket_latencies("composite"), RECOVERY_COMPOSITE_MEDIAN_MS),
        median_gate("recovery.vlm_median_latency_ms", bucket_latencies("vlm"), RECOVERY_COMPOSITE_MEDIAN_MS, required=False),
    ]
    return report, gates


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


# Reported but never required or failing: the marginal complete verdict is
# blocked until the RGB support term exists (ADR 0008 amendment), so these
# would fail every run for a reason no solver change can address.
DORMANT_GATES = {
    "verification.marginal.complete_precision",
    "verification.marginal.complete_recall",
}


def validate_triad_release(rows: list[dict[str, object]], kind: str) -> None:
    """Verification and registration rows enter a release corpus only from a
    device producer. None exists yet — every such row today is synthetic — so
    release mode fails these kinds honestly until one is built."""
    fixtures: set[str] = set()
    for index, row in enumerate(rows, start=1):
        label = f"release {kind} row {index}"
        if row.get("provenance") != "device":
            raise SystemExit(f"{label} has provenance {row.get('provenance')!r}; release needs 'device'")
        unique_fixture(row, fixtures, label)
        validate_release_device(row, label)
        model_id = row.get("authored_model_id")
        if not isinstance(model_id, str) or not model_id.strip():
            raise SystemExit(f"{label} authored_model_id must be non-empty")


def score_verification(rows: list[dict[str, object]]) -> tuple[dict[str, object], list[Gate]]:
    validate_verification_rows(rows)
    discriminable = [row for row in rows if row["detectability"] in {"strong", "marginal"}]
    # Undetectable negatives stay out of this denominator: including them
    # would make the bound easier to meet with rows the verifier abstains on
    # by construction. A "complete" on them is a separate hard failure.
    negatives = [row for row in discriminable if row["expected_verdict"] != "complete"]
    false_completes = [row for row in negatives if row["produced_verdict"] == "complete"]
    false_complete_gate = rate_gate(
        "verification.false_complete_rate",
        len(false_completes),
        len(negatives),
        ceiling=VERIFICATION_FALSE_COMPLETE_CEILING,
    )

    per_class: dict[str, dict[str, object]] = {}
    gates: list[Gate] = [false_complete_gate]
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
        for metric, events, trials, floor in (
            ("complete_precision", true_positive, true_positive + false_positive, VERIFICATION_PRECISION_FLOOR),
            ("complete_recall", true_positive, expected_complete, VERIFICATION_RECALL_FLOOR),
        ):
            name = f"verification.{detectability}.{metric}"
            gates.append(
                rate_gate(name, events, trials, floor=floor[detectability], dormant=name in DORMANT_GATES)
            )

    undetectable = [row for row in rows if row["detectability"] == "undetectable"]
    abstained = sum(row["produced_verdict"] == "uncertain" for row in undetectable)
    abstention_rate = abstained / len(undetectable) if undetectable else None
    undetectable_false_completes = sum(row["produced_verdict"] == "complete" for row in undetectable)

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
        "false_complete_rate": false_complete_gate.value,
        "false_complete_upper_95": false_complete_gate.bound,
        "false_complete_cases": len(false_completes),
        "negatives": len(negatives),
        "discriminable_cases": len(discriminable),
        "undetectable_cases": len(undetectable),
        "undetectable_false_completes": undetectable_false_completes,
        "per_detectability": per_class,
        "undetectable_abstention_rate": abstention_rate,
        "uncertain_on_correct_rate": uncertain_on_correct,
        "median_latency_ms": statistics.median(latencies) if latencies else None,
        "cases": len(rows),
    }
    colour = colour_term_report(rows)
    if colour is not None:
        report["colour_term"] = colour
    gates += [
        # A "complete" on a delta depth cannot see is never earned evidence.
        count_gate(
            "verification.undetectable_false_completes",
            undetectable_false_completes,
            0,
            trials=len(undetectable),
        ),
        rate_gate(
            "verification.undetectable_abstention_rate",
            abstained,
            len(undetectable),
            floor=VERIFICATION_ABSTENTION_FLOOR,
        ),
        rate_gate(
            "verification.uncertain_on_correct_rate",
            sum(row["produced_verdict"] == "uncertain" for row in correct_strong),
            len(correct_strong),
            ceiling=VERIFICATION_UNCERTAIN_ON_CORRECT_CEILING,
        ),
        median_gate("verification.median_latency_ms", latencies, VERIFICATION_MEDIAN_MS),
    ]
    return report, gates


def colour_term_report(rows: list[dict[str, object]]) -> dict[str, object] | None:
    """Informational only (ADR 0008 amendment, Proposed): how the colour term
    read replayed windows. Present only when rows carry it, so reports from
    runs without colour are unchanged. Its thresholds are RECONSTRUCTED; these
    counts are what Phase 1 tunes them on, never a gate."""
    coloured = [row for row in rows if row.get("colour_status") is not None]
    if not coloured:
        return None
    statuses: dict[str, int] = {}
    for row in coloured:
        statuses[str(row["colour_status"])] = statuses.get(str(row["colour_status"]), 0) + 1
    return {
        "modes": sorted({str(row.get("colour_term_mode")) for row in coloured}),
        "cases": len(coloured),
        "status_counts": dict(sorted(statuses.items())),
        # Disagreeing with a built step would block a true complete.
        "disagrees_on_expected_complete": sum(
            row["colour_status"] == "disagrees" and row["expected_verdict"] == "complete" for row in coloured
        ),
        # Agreeing on a negative would corroborate a false complete.
        "agrees_on_negatives": sum(
            row["colour_status"] == "agrees" and row["expected_verdict"] != "complete" for row in coloured
        ),
    }


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


# A stud pitch, and how close a final pose must sit to a whole number of
# pitches (with yaw near truth) to count as a lattice slip rather than noise.
STUD_PITCH_M = 0.008
PITCH_OFF_TOLERANCE_M = 0.002
PITCH_OFF_MAX_YAW_DEGREES = 5.0


def lattice_slip(row: dict[str, object]) -> tuple[int, int] | None:
    """The whole-pitch offset `(kx, kz)` a registration settled at, or None
    when it sits at truth, between pitches, at a turned yaw, or the row has
    no signed x/z error (rows from before 2026-10-07)."""
    dx, dz = row.get("translation_error_x_m"), row.get("translation_error_z_m")
    if not (is_number(dx) and is_number(dz)):
        return None
    if float(row["yaw_error_degrees"]) >= PITCH_OFF_MAX_YAW_DEGREES:
        return None
    kx, kz = round(float(dx) / STUD_PITCH_M), round(float(dz) / STUD_PITCH_M)
    if (kx, kz) == (0, 0):
        return None
    if abs(float(dx) - kx * STUD_PITCH_M) > PITCH_OFF_TOLERANCE_M:
        return None
    if abs(float(dz) - kz * STUD_PITCH_M) > PITCH_OFF_TOLERANCE_M:
        return None
    return kx, kz


def score_registration(rows: list[dict[str, object]]) -> tuple[dict[str, object], list[Gate]]:
    validate_registration_rows(rows)
    # A genuinely symmetric fixture cannot converge to a unique truth; it is
    # judged on reporting ambiguity, not on convergence.
    unambiguous = [row for row in rows if not row["ambiguity_expected"]]
    converged = [row for row in unambiguous if row["converged"]]
    convergence_rate = len(converged) / len(unambiguous) if unambiguous else None
    translation_errors = [float(row["translation_error_m"]) for row in converged]
    yaw_errors = [float(row["yaw_error_degrees"]) for row in converged]
    ambiguous_expected = [row for row in rows if row["ambiguity_expected"]]
    ambiguity_recall = (
        sum(row["reported_ambiguous"] for row in ambiguous_expected) / len(ambiguous_expected)
        if ambiguous_expected else None
    )
    # Lattice aliasing (Phase 4): a solve that settles a whole stud pitch
    # off at the right yaw is the failure stud keypoints exist to fix. Only
    # rows that carry signed x/z error can be judged.
    lattice_measured = [
        row for row in rows
        if is_number(row.get("translation_error_x_m")) and is_number(row.get("translation_error_z_m"))
    ]
    slips = [slip for slip in (lattice_slip(row) for row in lattice_measured) if slip is not None]
    by_runner_up: dict[str, int] = {}
    for row in rows:
        runner_up = row.get("lattice_runner_up")
        if isinstance(runner_up, str):
            by_runner_up[runner_up] = by_runner_up.get(runner_up, 0) + 1
    report: dict[str, object] = {
        "cases": len(rows),
        "convergence_rate": convergence_rate,
        "translation_rmse_m": rmse(translation_errors),
        "yaw_rmse_degrees": rmse(yaw_errors),
        "ambiguity_recall": ambiguity_recall,
        "ambiguity_expected_cases": len(ambiguous_expected),
        # The other half of ambiguity recall: a tracker that called every
        # pose ambiguous would recall perfectly while refusing to verify
        # anything (the safe side of ADR 0009, but still a failure).
        "unexpected_ambiguity_cases": sum(
            1 for row in rows if row["reported_ambiguous"] and not row["ambiguity_expected"]
        ),
        "lattice_measured_cases": len(lattice_measured),
        "pitch_off_cases": len(slips),
        "one_pitch_off_cases": sum(1 for kx, kz in slips if abs(kx) + abs(kz) == 1),
        "by_runner_up": by_runner_up,
    }
    gates = [
        rate_gate(
            "registration.convergence_rate",
            len(converged),
            len(unambiguous),
            floor=REGISTRATION_CONVERGENCE_FLOOR,
        ),
        rmse_gate("registration.translation_rmse_m", translation_errors, REGISTRATION_TRANSLATION_RMSE_M),
        rmse_gate("registration.yaw_rmse_degrees", yaw_errors, REGISTRATION_YAW_RMSE_DEGREES),
        rate_gate(
            "registration.ambiguity_recall",
            sum(row["reported_ambiguous"] for row in ambiguous_expected),
            len(ambiguous_expected),
            floor=REGISTRATION_AMBIGUITY_RECALL_FLOOR,
        ),
    ]
    return report, gates


# --- Challenge set (kind == "verification_challenge") -----------------------


def validate_challenge_rows(rows: list[dict[str, object]]) -> None:
    for index, row in enumerate(rows, start=1):
        label = f"challenge row {index}"
        if row.get("schema_version") != 1:
            raise SystemExit(f"{label} has unsupported schema")
        missing = sorted({"fixture_id", "challenge_class", "expected_verdict", "produced_verdict",
                          "detectability", "expected_failure", "latency_ms"} - row.keys())
        if missing:
            raise SystemExit(f"{label} missing fields: {', '.join(missing)}")
        if not isinstance(row["challenge_class"], str) or not row["challenge_class"]:
            raise SystemExit(f"{label} challenge_class must be a non-empty string")
        if row["expected_verdict"] not in VERDICTS or row["produced_verdict"] not in VERDICTS:
            raise SystemExit(f"{label} has an invalid verdict")
        if row["detectability"] not in DETECTABILITY:
            raise SystemExit(f"{label} has invalid detectability")
        if not isinstance(row["expected_failure"], bool):
            raise SystemExit(f"{label} expected_failure must be a boolean")
        require_valid_latency(row, label)


def score_challenge(rows: list[dict[str, object]]) -> dict[str, object]:
    """Per-class accounting. A false complete — "complete" where the build is
    wrong — is the number that matters. In an expected-failure class it is
    counted as `xfail` (the known blind spot, e.g. a colour swap depth cannot
    see); a class that stops failing reports `xpass`."""
    validate_challenge_rows(rows)
    by_class: dict[str, dict[str, object]] = {}
    for row in rows:
        entry = by_class.setdefault(row["challenge_class"], {
            "cases": 0,
            "expected_failure": row["expected_failure"],
            "produced": {verdict: 0 for verdict in sorted(VERDICTS)},
            "false_complete_cases": 0,
            "caught": 0,
            "abstained": 0,
            "correct_complete": 0,
            "false_alarms": 0,
            "negatives": 0,
        })
        entry["cases"] += 1
        entry["produced"][row["produced_verdict"]] += 1
        produced, expected = row["produced_verdict"], row["expected_verdict"]
        if produced == "uncertain":
            entry["abstained"] += 1
        if expected == "complete":
            entry["correct_complete"] += produced == "complete"
            entry["false_alarms"] += produced in {"incomplete", "misplaced"}
        else:
            entry["negatives"] += 1
            entry["false_complete_cases"] += produced == "complete"
            entry["caught"] += produced in {"incomplete", "misplaced"}
    for entry in by_class.values():
        if entry["expected_failure"]:
            entry["xfail"] = entry["false_complete_cases"]
            entry["xpass"] = entry["cases"] - entry["false_complete_cases"]
    return {
        "cases": len(rows),
        "false_complete_cases": sum(
            entry["false_complete_cases"] for entry in by_class.values() if not entry["expected_failure"]
        ),
        "expected_failure_false_complete_cases": sum(
            entry["false_complete_cases"] for entry in by_class.values() if entry["expected_failure"]
        ),
        "by_class": by_class,
    }


def validate_vlm_check_release(rows: list[dict[str, object]], kind: str = VLM_CHECK_KIND) -> None:
    """Step-check rows enter a release corpus only from a device session with
    a label declared before capture. Mac replays (provenance `replay`) are
    refused as for every kind. So are confirmed labels: a step is confirmed
    only after the user accepted a check, so those labels lean toward
    complete and would understate the false-complete rate."""
    fixtures: set[str] = set()
    for index, row in enumerate(rows, start=1):
        label = f"release {kind} row {index}"
        if row.get("provenance") != "device":
            raise SystemExit(f"{label} has provenance {row.get('provenance')!r}; release needs 'device'")
        unique_fixture(row, fixtures, label)
        validate_release_device(row, label)
        if row.get("label_kind") != "staged":
            raise SystemExit(f"{label} has label_kind {row.get('label_kind')!r}; release needs 'staged'")
        if row.get("physical_case") is not True:
            raise SystemExit(f"{label} is not explicitly marked as a physical case")
        if row.get("legal_use_confirmed") is not True:
            raise SystemExit(f"{label} lacks confirmed legal-use provenance")
        model_id = row.get("authored_model_id")
        if not isinstance(model_id, str) or not model_id.strip():
            raise SystemExit(f"{label} authored_model_id must be non-empty")


def score_vlm_check(rows: list[dict[str, object]]) -> dict[str, object]:
    for index, row in enumerate(rows, start=1):
        label = f"vlm_check row {index}"
        missing = sorted({"fixture_id", "expected_verdict", "produced_verdict", "latency_ms"} - row.keys())
        if missing:
            raise SystemExit(f"{label} missing fields: {', '.join(missing)}")
        if row["expected_verdict"] not in {"complete", "incomplete"}:
            raise SystemExit(f"{label} expected_verdict must be complete or incomplete")
        if row["produced_verdict"] not in CHECK_VERDICTS:
            raise SystemExit(f"{label} has an invalid produced_verdict")
        require_valid_latency(row, label)
    negatives = [row for row in rows if row["expected_verdict"] == "incomplete"]
    positives = [row for row in rows if row["expected_verdict"] == "complete"]
    false_completes = sum(row["produced_verdict"] == "complete" for row in negatives)
    gate = rate_gate(
        "vlm_check.false_complete_rate", false_completes, len(negatives),
        ceiling=VERIFICATION_FALSE_COMPLETE_CEILING, required=False,
    )
    return {
        "cases": len(rows),
        "negatives": len(negatives),
        "false_complete_cases": false_completes,
        "false_complete_rate": gate.value,
        "false_complete_upper_95": gate.bound,
        "complete_recall": (
            sum(row["produced_verdict"] == "complete" for row in positives) / len(positives) if positives else None
        ),
        "uncertain_rate": sum(row["produced_verdict"] == "uncertain" for row in rows) / len(rows),
        "decode_failures": sum(bool(row.get("decode_failed")) for row in rows),
    }


def validate_placement_rows(rows: list[dict[str, object]]) -> None:
    for index, row in enumerate(rows, start=1):
        label = f"placement row {index}"
        if row.get("schema_version") != 1:
            raise SystemExit(f"{label} has unsupported schema")
        missing = sorted({"fixture_id", "expected_state", "produced_state"} - row.keys())
        if missing:
            raise SystemExit(f"{label} missing fields: {', '.join(missing)}")
        if row["expected_state"] not in PLACEMENT_STATES or row["produced_state"] not in PLACEMENT_STATES:
            raise SystemExit(f"{label} has an invalid placement state")


def score_placement(rows: list[dict[str, object]]) -> tuple[dict[str, object], list[Gate]]:
    """The build diff's headline is false present: a placement that is not
    there as authored (absent, shifted, turned) read as present. Observe-only
    rows (plate steps) and expected failures (a colour swap) never count."""
    validate_placement_rows(rows)
    scored = [row for row in rows if not row.get("observe_only") and not row.get("expected_failure")]
    negatives = [row for row in scored if row["expected_state"] != "present"]
    false_present = [row for row in negatives if row["produced_state"] == "present"]
    gate = rate_gate(
        "placement.false_present_rate", len(false_present), len(negatives),
        ceiling=PLACEMENT_FALSE_PRESENT_CEILING, required=False,
    )
    by_expected: dict[str, dict[str, int]] = {}
    for row in scored:
        produced = by_expected.setdefault(row["expected_state"], {})
        produced[row["produced_state"]] = produced.get(row["produced_state"], 0) + 1
    positives = [row for row in scored if row["expected_state"] == "present"]
    report = {
        "cases": len(rows),
        "negatives": len(negatives),
        "false_present_cases": len(false_present),
        "false_present_rate": gate.value,
        "false_present_upper_95": gate.bound,
        "undetectable_false_present_cases": sum(row.get("detectability") == "undetectable" for row in false_present),
        "observe_only_cases": sum(bool(row.get("observe_only")) for row in rows),
        "expected_failure_cases": sum(bool(row.get("expected_failure")) for row in rows),
        "present_recall": (
            sum(row["produced_state"] == "present" for row in positives) / len(positives) if positives else None
        ),
        "by_expected_state": by_expected,
    }
    return report, [gate]


def score_repair(rows: list[dict[str, object]]) -> tuple[dict[str, object], list[Gate]]:
    for index, row in enumerate(rows, start=1):
        missing = sorted({"fixture_id", "harmful_actions", "expected_actions", "produced_actions"} - row.keys())
        if missing:
            raise SystemExit(f"repair_plan row {index} missing fields: {', '.join(missing)}")
        if not is_exact_int(row["harmful_actions"]) or row["harmful_actions"] < 0:
            raise SystemExit(f"repair_plan row {index} harmful_actions must be a non-negative integer")
    harmful = sum(row["harmful_actions"] for row in rows)
    directed = [row for row in rows if row.get("produced_direction") not in (None, "none")
                and row.get("expected_direction") not in (None, "none")]
    agreeing = sum(row["produced_direction"] == row["expected_direction"] for row in directed)
    gate = count_gate("repair_plan.harmful_actions", harmful, 0, trials=len(rows))
    # Cross-step rows (M2.9) carry no direction; a withheld plan matches an
    # empty expectation.
    cross_step = [row for row in rows if row.get("scope") == "cross_step"]
    report = {
        "cases": len(rows),
        "cross_step_cases": len(cross_step),
        "cross_step_matching_cases": sum(row["produced_actions"] == row["expected_actions"] for row in cross_step),
        "cross_step_harmful_actions": sum(row["harmful_actions"] for row in cross_step),
        "plans_produced": sum(bool(row["produced_actions"]) for row in rows),
        "plans_matching": sum(row["produced_actions"] == row["expected_actions"] for row in rows if row["produced_actions"]),
        "harmful_actions": harmful,
        "directed_cases": len(directed),
        "direction_disagreement_cases": len(directed) - agreeing,
        "direction_agreement": agreeing / len(directed) if directed else None,
    }
    return report, [gate]


def score_geometric_recovery(rows: list[dict[str, object]]) -> dict[str, object]:
    for index, row in enumerate(rows, start=1):
        missing = sorted({"fixture_id", "scenario_class", "expected_step_id", "ranked_step_ids", "certainty"} - row.keys())
        if missing:
            raise SystemExit(f"geometric_recovery row {index} missing fields: {', '.join(missing)}")

    def summary(group: list[dict[str, object]]) -> dict[str, object]:
        top1 = sum(bool(r["ranked_step_ids"]) and r["ranked_step_ids"][0] == r["expected_step_id"] for r in group)
        top3 = sum(r["expected_step_id"] in r["ranked_step_ids"][:3] for r in group)
        insufficient = sum(r["certainty"] == "insufficient" for r in group)
        return {
            "cases": len(group),
            "top1_cases": top1,
            "top3_cases": top3,
            "insufficient_cases": insufficient,
            "tie_break_cases": sum(bool(r.get("tie_break_applied")) for r in group),
            "top1_rate": top1 / len(group) if group else None,
        }

    by_class: dict[str, list[dict[str, object]]] = {}
    for row in rows:
        by_class.setdefault(str(row["scenario_class"]), []).append(row)
    report = summary(rows)
    report["by_class"] = {name: summary(group) for name, group in sorted(by_class.items())}
    return report


def score_placement_suggestion(rows: list[dict[str, object]]) -> tuple[dict[str, object], list[Gate]]:
    for index, row in enumerate(rows, start=1):
        if row.get("outcome") not in {"correct", "wrong", "none"}:
            raise SystemExit(f"placement_suggestion row {index} has an invalid outcome")
    proposals = [row for row in rows if row["outcome"] != "none"]
    wrong = [row for row in proposals if row["outcome"] == "wrong"]
    gate = rate_gate(
        "placement_suggestion.wrong_proposal_rate", len(wrong), len(proposals),
        ceiling=WRONG_PROPOSAL_CEILING, required=False,
    )
    by_scenario: dict[str, dict[str, int]] = {}
    for row in rows:
        entry = by_scenario.setdefault(str(row.get("scenario", "unknown")), {"correct": 0, "wrong": 0, "none": 0})
        entry[row["outcome"]] += 1
    report = {
        "cases": len(rows),
        "proposal_cases": len(proposals),
        "wrong_proposal_cases": len(wrong),
        "no_proposal_cases": len(rows) - len(proposals),
        "wrong_proposal_rate": gate.value,
        "wrong_proposal_upper_95": gate.bound,
        "by_scenario": by_scenario,
    }
    return report, [gate]


def challenge_lines(report: dict[str, object]) -> list[str]:
    lines = []
    for name, entry in sorted(report["by_class"].items()):
        suffix = " XFAIL" if entry["expected_failure"] else ""
        lines.append(f"CHALLENGE_FALSE_COMPLETE {name} {entry['false_complete_cases']}/{entry['negatives']}{suffix}")
    return lines


def score_shadow_check(rows: list[dict[str, object]]) -> dict[str, object]:
    """The advisor's case for ADR 0018, informational until device rows
    exist: its standalone false-complete rate on staged negatives (the
    decision needs the bound under 2% with at least 149 negatives), and what
    its only-toward-incomplete merge did to the primary verdicts."""
    for index, row in enumerate(rows, start=1):
        label = f"{SHADOW_CHECK_KIND} row {index}"
        required = {"fixture_id", "expected_verdict", "primary_verdict", "standalone_verdict", "merged_verdict", "latency_ms"}
        missing = sorted(required - row.keys())
        if missing:
            raise SystemExit(f"{label} missing fields: {', '.join(missing)}")
        if row["expected_verdict"] not in {"complete", "incomplete"}:
            raise SystemExit(f"{label} expected_verdict must be complete or incomplete")
        if row["primary_verdict"] not in CHECK_VERDICTS or row["merged_verdict"] not in CHECK_VERDICTS:
            raise SystemExit(f"{label} has an invalid primary or merged verdict")
        if row["standalone_verdict"] not in CHECK_VERDICTS | {"none"}:
            raise SystemExit(f"{label} has an invalid standalone_verdict")
        if row["primary_verdict"] != "complete" and row["merged_verdict"] != row["primary_verdict"]:
            raise SystemExit(f"{label} merged a {row['primary_verdict']} verdict; the advisor may only take a complete away")
        require_valid_latency(row, label)
    answered = [row for row in rows if row["standalone_verdict"] != "none"]
    negatives = [row for row in answered if row["expected_verdict"] == "incomplete"]
    positives = [row for row in answered if row["expected_verdict"] == "complete"]
    standalone_false_completes = sum(row["standalone_verdict"] == "complete" for row in negatives)
    gate = rate_gate(
        "shadow_check.standalone_false_complete_rate", standalone_false_completes, len(negatives),
        ceiling=VERIFICATION_FALSE_COMPLETE_CEILING, required=False,
    )
    all_negatives = [row for row in rows if row["expected_verdict"] == "incomplete"]
    flips = [row for row in rows if row["merged_verdict"] != row["primary_verdict"]]
    closed: dict[str, int] = {}
    for row in rows:
        answer = str(row.get("closed_answer") or "none")
        closed[answer] = closed.get(answer, 0) + 1
    needed = zero_miss_minimum(gate) or 0
    return {
        "cases": len(rows),
        "answered": len(answered),
        "negatives": len(negatives),
        "standalone_false_complete_cases": standalone_false_completes,
        "standalone_false_complete_rate": gate.value,
        "standalone_false_complete_upper_95": gate.bound,
        "negatives_still_needed": max(0, needed - len(negatives)),
        "standalone_complete_recall": (
            sum(row["standalone_verdict"] == "complete" for row in positives) / len(positives) if positives else None
        ),
        "primary_false_complete_cases": sum(row["primary_verdict"] == "complete" for row in all_negatives),
        "merged_false_complete_cases": sum(row["merged_verdict"] == "complete" for row in all_negatives),
        "flips": len(flips),
        "flips_caught_a_negative": sum(row["expected_verdict"] == "incomplete" for row in flips),
        "flips_lost_a_complete": sum(row["expected_verdict"] == "complete" for row in flips),
        "closed_answers": dict(sorted(closed.items())),
    }


# --- Lattice windows (kind == "lattice_window") -----------------------------


def lattice_trouble(row: dict[str, object]) -> bool:
    """A staged window the stud lattice went wrong on: the verifier refused
    for an ambiguous pose, at least half its frames were ambiguous, a
    complete build was called one stud off, or a one-stud shift complete."""
    frames = int(row["frames"])
    return (
        row.get("uncertain_reason") == "poseAmbiguous"
        or (frames > 0 and 2 * int(row["ambiguous_frames"]) >= frames)
        or (row.get("staged_scenario") == "complete" and row["verdict"] == "misplaced")
        or (row.get("staged_scenario") == "shifted_one_stud" and row["verdict"] == "complete")
    )


def lattice_entry(population: list[dict[str, object]]) -> dict[str, object]:
    """The stud-keypoint entry readout. MET needs the lower bound at or
    above 5%; NOT MET, the upper bound below it; anything else, including
    no rows at all, is UNMEASURED and says why — never a silent pass."""
    windows = len(population)
    sessions = len({str(row["session_id"]) for row in population})
    events = sum(lattice_trouble(row) for row in population)
    lower = clopper_pearson_lower(events, windows) if windows else None
    upper = clopper_pearson_upper(events, windows) if windows else None
    if windows < LATTICE_ENTRY_MINIMUM_WINDOWS:
        status, reason = UNMEASURED, f"{windows} device windows, need {LATTICE_ENTRY_MINIMUM_WINDOWS}"
    elif sessions < LATTICE_ENTRY_MINIMUM_SESSIONS:
        status, reason = UNMEASURED, f"{sessions} sessions, need {LATTICE_ENTRY_MINIMUM_SESSIONS}"
    elif lower is not None and lower >= LATTICE_ENTRY_RATE:
        status, reason = "MET", f"{events}/{windows} windows, lower95={lower:.4f}"
    elif upper is not None and upper < LATTICE_ENTRY_RATE:
        status, reason = "NOT_MET", f"{events}/{windows} windows, upper95={upper:.4f}"
    else:
        status, reason = UNMEASURED, (
            f"inconclusive: {events}/{windows} windows, bounds {format_number(lower)}..{format_number(upper)} straddle "
            f"{LATTICE_ENTRY_RATE:g}"
        )
    return {
        "status": status,
        "reason": reason,
        "windows": windows,
        "sessions": sessions,
        "events": events,
        "lower_95": lower,
        "upper_95": upper,
    }


def score_lattice(rows: list[dict[str, object]]) -> dict[str, object]:
    """Lattice evidence from verification windows, informational. Only
    device rows (an iPhone, not a replay or a synthetic session) from
    windows that closed on a staged complete or one-stud-shift build count
    toward the entry readout."""
    required = {
        "fixture_id", "session_id", "provenance", "device_model", "trigger", "verdict", "frames",
        "swept_frames", "ambiguous_frames", "locked_frames", "locked_near_threshold_frames", "margins", "runner_ups",
    }
    for index, row in enumerate(rows, start=1):
        label = f"{LATTICE_WINDOW_KIND} row {index}"
        if row.get("schema_version") != 1:
            raise SystemExit(f"{label} has unsupported schema")
        missing = sorted(required - row.keys())
        if missing:
            raise SystemExit(f"{label} missing fields: {', '.join(missing)}")
        if not isinstance(row["margins"], list) or not all(is_number(value) for value in row["margins"]):
            raise SystemExit(f"{label} margins must be a list of finite numbers")
    device = [
        row for row in rows
        if row["provenance"] == "device" and str(row["device_model"]).startswith("iPhone")
    ]
    closing = [row for row in device if row["trigger"] != "verdict_change"]
    population = [row for row in closing if row.get("staged_scenario") in LATTICE_ENTRY_SCENARIOS]
    margins = [float(value) for row in device for value in row["margins"]]
    frames = sum(int(row["frames"]) for row in device)
    locked = sum(int(row["locked_frames"]) for row in device)
    runner_ups: dict[str, int] = {}
    for row in device:
        for name, count in dict(row["runner_ups"]).items():
            runner_ups[name] = runner_ups.get(name, 0) + int(count)
    return {
        "windows": len(rows),
        "device_windows": len(device),
        "closing_device_windows": len(closing),
        "margin_p10": percentile(margins, 0.10) if margins else None,
        "margin_p50": percentile(margins, 0.50) if margins else None,
        "margin_p90": percentile(margins, 0.90) if margins else None,
        "ambiguous_frame_rate": sum(int(row["ambiguous_frames"]) for row in device) / frames if frames else None,
        "pose_ambiguous_window_rate": (
            sum(row.get("uncertain_reason") == "poseAmbiguous" for row in closing) / len(closing) if closing else None
        ),
        "locked_near_threshold_rate": (
            sum(int(row["locked_near_threshold_frames"]) for row in device) / locked if locked else None
        ),
        "complete_called_misplaced": sum(
            row.get("staged_scenario") == "complete" and row["verdict"] == "misplaced" for row in closing
        ),
        "shifted_called_complete": sum(
            row.get("staged_scenario") == "shifted_one_stud" and row["verdict"] == "complete" for row in closing
        ),
        "runner_ups": dict(sorted(runner_ups.items())),
        "entry": lattice_entry(population),
    }


def lattice_entry_line(report: dict[str, object] | None) -> str:
    entry = report["entry"] if report else lattice_entry([])
    return f"STUD_KEYPOINTS_ENTRY {entry['status']} ({entry['reason']})"


# --- Entry -------------------------------------------------------------------


def partition(rows: list[dict[str, object]]) -> dict[str, list[dict[str, object]]]:
    kinds: dict[str, list[dict[str, object]]] = {
        kind: [] for kind in KINDS + SUMMARY_KINDS + (
            CHALLENGE_KIND, VLM_CHECK_KIND, SHADOW_CHECK_KIND, PLACEMENT_KIND, REPAIR_KIND, GEOMETRIC_RECOVERY_KIND,
            PLACEMENT_SUGGESTION_KIND, LATTICE_WINDOW_KIND,
        )
    }
    for index, row in enumerate(rows, start=1):
        kind = row.get("kind", "recovery")
        if kind not in kinds:
            raise SystemExit(f"row {index} has unknown kind: {kind}")
        kinds[kind].append(row)
    return kinds


def zero_miss_minimum(gate: Gate) -> int | None:
    """Smallest sample that can pass `gate` in release mode with no misses."""
    for n in range(1, 100_000):
        if gate.name.endswith("median_latency_ms"):
            if median_upper_bound([0.0] * n) is not None:
                return n
            continue
        if gate.name.endswith("_rmse_m") or gate.name.endswith("_rmse_degrees"):
            return MINIMUM_RMSE_SAMPLES
        bound = clopper_pearson_upper(0, n) if gate.comparator == "max" else clopper_pearson_lower(n, n)
        if bound is not None and (bound <= gate.threshold if gate.comparator == "max" else bound >= gate.threshold):
            return n
    return None


def explain_minimums() -> None:
    """Print the zero-miss sample size each release gate implies."""
    empty_verification = [
        {"schema_version": 1, "fixture_id": "x", "expected_verdict": "complete",
         "produced_verdict": "complete", "detectability": "strong", "latency_ms": 0}
    ]
    empty_registration = [
        {"schema_version": 1, "fixture_id": "x", "converged": True, "translation_error_m": 0.0,
         "yaw_error_degrees": 0.0, "ambiguity_expected": False, "reported_ambiguous": False,
         "latency_ms": 0}
    ]
    gates = (
        score_verification(empty_verification)[1]
        + score_registration(empty_registration)[1]
        + [
            rate_gate("recovery.top_3_accuracy", 1, 1, floor=RECOVERY_TOP3_FLOOR),
            rate_gate("recovery.top_1_accuracy", 1, 1, floor=RECOVERY_TOP1_FLOOR),
            median_gate("recovery.geometric_median_latency_ms", [0.0], RECOVERY_GEOMETRIC_MEDIAN_MS),
            median_gate("recovery.composite_median_latency_ms", [0.0], RECOVERY_COMPOSITE_MEDIAN_MS),
        ]
    )
    print(f"Zero-miss sample size per release gate at {CONFIDENCE:.0%} one-sided confidence:")
    for gate in gates:
        if gate.name == "verification.undetectable_false_completes":
            continue
        suffix = " (dormant)" if gate.dormant else ""
        symbol = ">=" if gate.comparator == "min" else "<="
        print(f"  {gate.name} {symbol} {gate.threshold:g}: n >= {zero_miss_minimum(gate)}{suffix}")


def format_number(value: float | None) -> str:
    return "-" if value is None else f"{value:.4f}"


def headline(verification_report: dict[str, object] | None, gate: Gate | None, *, release: bool) -> str:
    if verification_report is None or gate is None:
        return f"FALSE_COMPLETE_RATE {UNMEASURED} (no verification rows) {UNMEASURED}"
    rate = verification_report["false_complete_rate"]
    shown = UNMEASURED if rate is None else f"{rate:.4f}"
    return (
        f"FALSE_COMPLETE_RATE {shown} "
        f"({verification_report['false_complete_cases']}/{verification_report['negatives']} negatives, "
        f"upper95={format_number(gate.bound)}) {gate.status(release=release)}"
    )


def require_single_arm(rows: list[dict[str, object]]) -> None:
    """One file, one arm. Pooling a baseline and a variant would score a
    blend that no build ships; comparisons belong to compare_arms.py."""
    arms = sorted({str(row.get("variant_id") or "unrecorded") for row in rows})
    if len(arms) > 1:
        raise SystemExit(
            f"rows come from {len(arms)} inference variants ({', '.join(arms)}); "
            "score each arm separately or compare them with compare_arms.py "
            "(--allow-mixed-arms overrides)"
        )


def main(
    path: Path,
    *,
    informational: bool = False,
    require_kinds: set[str] | None = None,
    allow_mixed_arms: bool = False,
) -> None:
    release = not informational
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows:
        raise SystemExit("no benchmark rows")
    if require_kinds is None:
        require_kinds = set(KINDS) if release else set()
    kinds = partition(rows)
    if not allow_mixed_arms:
        require_single_arm(kinds["recovery"])
    if release:
        for kind in SUMMARY_KINDS:
            if kinds[kind]:
                raise SystemExit(f"{kind} rows describe a synthetic corpus and are not release evidence")
        if kinds[CHALLENGE_KIND]:
            raise SystemExit(f"{CHALLENGE_KIND} rows are a synthetic challenge set and are not release evidence")
        if kinds[VLM_CHECK_KIND]:
            validate_vlm_check_release(kinds[VLM_CHECK_KIND])
        if kinds[SHADOW_CHECK_KIND]:
            validate_vlm_check_release(kinds[SHADOW_CHECK_KIND], kind=SHADOW_CHECK_KIND)
        if any(row.get("provenance") != "device" for row in kinds[PLACEMENT_KIND]):
            raise SystemExit(f"{PLACEMENT_KIND} rows other than device rows are not release evidence")
        if kinds[REPAIR_KIND]:
            raise SystemExit(f"{REPAIR_KIND} rows are synthetic and are not release evidence")
        if kinds[GEOMETRIC_RECOVERY_KIND]:
            raise SystemExit(f"{GEOMETRIC_RECOVERY_KIND} rows are synthetic and are not release evidence")
        if any(row.get("provenance") != "device" for row in kinds[PLACEMENT_SUGGESTION_KIND]):
            raise SystemExit(f"{PLACEMENT_SUGGESTION_KIND} rows other than device rows are not release evidence")
        for kind in ("verification", "registration"):
            if kinds[kind]:
                validate_triad_release(kinds[kind], kind)
    scorers = {
        "verification": lambda kind_rows: score_verification(kind_rows),
        "registration": lambda kind_rows: score_registration(kind_rows),
        "recovery": lambda kind_rows: score_recovery(kind_rows, release=release),
    }
    report: dict[str, object] = {}
    gates_by_kind: dict[str, list[Gate]] = {}
    for kind in ("verification", "registration", "recovery"):
        if kinds[kind]:
            report[kind], gates_by_kind[kind] = scorers[kind](kinds[kind])
    for kind in SUMMARY_KINDS:
        if kinds[kind]:
            report[kind] = kinds[kind]
    if kinds[CHALLENGE_KIND]:
        report[CHALLENGE_KIND] = score_challenge(kinds[CHALLENGE_KIND])
    if kinds[VLM_CHECK_KIND]:
        report[VLM_CHECK_KIND] = score_vlm_check(kinds[VLM_CHECK_KIND])
    if kinds[SHADOW_CHECK_KIND]:
        report[SHADOW_CHECK_KIND] = score_shadow_check(kinds[SHADOW_CHECK_KIND])
    if kinds[LATTICE_WINDOW_KIND]:
        report[LATTICE_WINDOW_KIND] = score_lattice(kinds[LATTICE_WINDOW_KIND])
    placement_gates: list[Gate] = []
    if kinds[PLACEMENT_KIND]:
        report[PLACEMENT_KIND], placement_gates = score_placement(kinds[PLACEMENT_KIND])
    repair_gates: list[Gate] = []
    if kinds[REPAIR_KIND]:
        report[REPAIR_KIND], repair_gates = score_repair(kinds[REPAIR_KIND])
    if kinds[PLACEMENT_SUGGESTION_KIND]:
        report[PLACEMENT_SUGGESTION_KIND], suggestion_gates = score_placement_suggestion(kinds[PLACEMENT_SUGGESTION_KIND])
        suggestion = report[PLACEMENT_SUGGESTION_KIND]
        print(
            f"PLACEMENT_SUGGESTION_WRONG {suggestion['wrong_proposal_cases']}/{suggestion['proposal_cases']} proposals "
            f"(upper95={format_number(suggestion['wrong_proposal_upper_95'])}, {suggestion['no_proposal_cases']} declined)"
        )
        suggestion["gates"] = {gate.name: gate.summary(release=release) for gate in suggestion_gates}
    if kinds[GEOMETRIC_RECOVERY_KIND]:
        report[GEOMETRIC_RECOVERY_KIND] = score_geometric_recovery(kinds[GEOMETRIC_RECOVERY_KIND])
        for name, entry in report[GEOMETRIC_RECOVERY_KIND]["by_class"].items():
            print(
                f"GEOMETRIC_RECOVERY {name} top1 {entry['top1_cases']}/{entry['cases']} "
                f"top3 {entry['top3_cases']}/{entry['cases']} insufficient {entry['insufficient_cases']}"
            )

    # The headline number, printed before anything else (ADR 0008) — even
    # when it could not be measured, so its absence is never silent.
    false_complete_gate = next(
        (gate for gate in gates_by_kind.get("verification", []) if gate.name == "verification.false_complete_rate"),
        None,
    )
    print(headline(report.get("verification"), false_complete_gate, release=release))
    # Printed on every run, like the headline: no device rows reads as
    # UNMEASURED, never as a criterion met or failed.
    print(lattice_entry_line(report.get(LATTICE_WINDOW_KIND)))
    if VLM_CHECK_KIND in report:
        check = report[VLM_CHECK_KIND]
        shown = UNMEASURED if check["false_complete_rate"] is None else f"{check['false_complete_rate']:.4f}"
        print(
            f"VLM_CHECK_FALSE_COMPLETE {shown} ({check['false_complete_cases']}/{check['negatives']} negatives, "
            f"upper95={format_number(check['false_complete_upper_95'])})"
        )
    if SHADOW_CHECK_KIND in report:
        shadow = report[SHADOW_CHECK_KIND]
        shown = UNMEASURED if shadow["standalone_false_complete_rate"] is None else f"{shadow['standalone_false_complete_rate']:.4f}"
        print(
            f"SHADOW_CHECK_STANDALONE_FALSE_COMPLETE {shown} ({shadow['standalone_false_complete_cases']}/"
            f"{shadow['negatives']} negatives, upper95={format_number(shadow['standalone_false_complete_upper_95'])}; "
            f"{shadow['negatives_still_needed']} more negatives at zero misses for ADR 0018)"
        )
    if PLACEMENT_KIND in report:
        placement = report[PLACEMENT_KIND]
        shown = UNMEASURED if placement["false_present_rate"] is None else f"{placement['false_present_rate']:.4f}"
        print(
            f"PLACEMENT_FALSE_PRESENT {shown} ({placement['false_present_cases']}/{placement['negatives']} negatives, "
            f"upper95={format_number(placement['false_present_upper_95'])})"
        )
        for gate in placement_gates:
            status = gate.status(release=release)
            failed_placement = gate.fails(release=release)
            print(
                f"GATE {gate.name} {status} value={format_number(gate.value)} "
                f"bound={format_number(gate.bound)} n={gate.trials} threshold<={gate.threshold:g}"
            )
            placement["gates"] = {gate.name: gate.summary(release=release)}
            if failed_placement:
                print("(informational until real verification windows exist; never fails the run)")
    if REPAIR_KIND in report:
        repair = report[REPAIR_KIND]
        print(
            f"REPAIR_HARMFUL_ACTIONS {repair['harmful_actions']} ({repair['cases']} cases, "
            f"{repair['plans_produced']} plans, direction agreement {format_number(repair['direction_agreement'])})"
        )
    if CHALLENGE_KIND in report:
        for line in challenge_lines(report[CHALLENGE_KIND]):
            print(line)

    # A harmful repair action fails the run in either mode: it would make a
    # build worse, which no corpus size excuses.
    failed = any(gate.fails(release=True) for gate in repair_gates)
    for gate in repair_gates:
        print(f"GATE {gate.name} {gate.status(release=True)} value={format_number(gate.value)} n={gate.trials} threshold<={gate.threshold:g}")
    for kind in KINDS:
        if not kinds[kind]:
            required = kind in require_kinds
            failed = failed or required
            print(f"KIND {kind} {UNMEASURED}{' (required: FAIL)' if required else ''}")
            continue
        summaries: dict[str, object] = {}
        for gate in gates_by_kind[kind]:
            status = gate.status(release=release)
            failed = failed or gate.fails(release=release)
            print(
                f"GATE {gate.name} {status} value={format_number(gate.value)} "
                f"bound={format_number(gate.bound)} n={gate.trials} "
                f"threshold{'>=' if gate.comparator == 'min' else '<='}{gate.threshold:g}"
            )
            summaries[gate.name] = gate.summary(release=release)
        report[kind]["gates"] = summaries
    print(json.dumps(report, indent=2, sort_keys=True))
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("results", type=Path, nargs="?", metavar="DEVICE_RESULTS.ndjson")
    parser.add_argument(
        "--informational",
        "--allow-small-corpus",
        dest="informational",
        action="store_true",
        help="judge point estimates and only report UNMEASURED gates (smoke data, CI trends); "
        "never for release decisions",
    )
    parser.add_argument(
        "--require-kinds",
        help="comma-separated row kinds that must be present "
        "(default: all three in release mode, none in informational mode)",
    )
    parser.add_argument(
        "--allow-mixed-arms",
        action="store_true",
        help="score recovery rows from several inference variants together",
    )
    parser.add_argument(
        "--explain-minimums",
        action="store_true",
        help="print the zero-miss sample size each release gate implies and exit",
    )
    arguments = parser.parse_args()
    if arguments.explain_minimums:
        explain_minimums()
        raise SystemExit(0)
    if arguments.results is None:
        parser.error("DEVICE_RESULTS.ndjson is required")
    required = None
    if arguments.require_kinds is not None:
        required = {kind.strip() for kind in arguments.require_kinds.split(",") if kind.strip()}
        unknown = required - set(KINDS)
        if unknown:
            parser.error(f"unknown kinds: {', '.join(sorted(unknown))}")
    main(
        arguments.results,
        informational=arguments.informational,
        require_kinds=required,
        allow_mixed_arms=arguments.allow_mixed_arms,
    )
