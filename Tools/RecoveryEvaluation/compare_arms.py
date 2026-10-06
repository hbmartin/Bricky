#!/usr/bin/env python3
"""Paired A/B comparison of bricky-harness replay arms (ADR 0010 amendment).

Each arm is a `bricky-harness replay --out ARM.ndjson` output. Its sidecars
(`ARM.ndjson.traces.ndjson`, `ARM.ndjson.checks.ndjson`) are read too when
present. Rows are paired across arms by identity — trace for passes, fixture
for sessions and checks — so every comparison is on the same evidence:

    python3 compare_arms.py --control control.ndjson --variant feed_all.ndjson
    python3 compare_arms.py --control c.ndjson --variant a.ndjson --variant b.ndjson

Accuracy uses an exact two-sided McNemar test on the discordant pairs, Holm-
corrected across variants. With no losses it takes at least 6 wins to reach
p < 0.05. Latency is the paired ratio of the variant to the control, and a
difference under 5% counts as none. A variant is a Mac-replay flip candidate
only if it wins (or holds accuracy with at least a 5% latency win) without
raising the insufficient or false-complete rate. Device rows are still
required before the default flips.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
from dataclasses import dataclass, field
from pathlib import Path

ALPHA = 0.05
LATENCY_NOISE = 0.05
# Below this many paired passes a verdict is an anecdote: a latency "win"
# with no accuracy loss is trivially true when neither arm got anything
# right, as on a synthetic board where every answer is "insufficient".
MINIMUM_PAIRS = 20
SLOTS = "ABCDEFGH"


def read_ndjson(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


@dataclass
class Arm:
    name: str
    sessions: dict[str, dict[str, object]]
    passes: dict[str, dict[str, object]]
    checks: dict[str, dict[str, object]]

    @classmethod
    def load(cls, path: Path) -> "Arm":
        def keyed(rows: list[dict[str, object]], key: str) -> dict[str, dict[str, object]]:
            return {str(row[key]): row for row in rows if key in row}
        return cls(
            name=path.name,
            sessions=keyed(read_ndjson(path), "fixture_id"),
            passes=keyed(read_ndjson(Path(f"{path}.traces.ndjson")), "trace_id"),
            checks=keyed(read_ndjson(Path(f"{path}.checks.ndjson")), "fixture_id"),
        )


def mcnemar_exact(wins: int, losses: int) -> float:
    """Two-sided exact McNemar p-value from the discordant pairs: `wins`
    where only the variant was right, `losses` where only the control was."""
    discordant = wins + losses
    if discordant == 0:
        return 1.0
    tail = sum(math.comb(discordant, k) for k in range(min(wins, losses) + 1)) / 2 ** discordant
    return min(1.0, 2 * tail)


def holm(p_values: list[float]) -> list[float]:
    """Holm step-down adjusted p-values, in the input order."""
    order = sorted(range(len(p_values)), key=lambda index: p_values[index])
    adjusted = [0.0] * len(p_values)
    running = 0.0
    for rank, index in enumerate(order):
        running = max(running, min(1.0, (len(p_values) - rank) * p_values[index]))
        adjusted[index] = running
    return adjusted


@dataclass
class Paired:
    pairs: int = 0
    wins: int = 0
    losses: int = 0
    both_right: int = 0

    @property
    def p_value(self) -> float:
        return mcnemar_exact(self.wins, self.losses)

    def add(self, control_right: bool, variant_right: bool) -> None:
        self.pairs += 1
        if control_right and variant_right:
            self.both_right += 1
        elif variant_right:
            self.wins += 1
        elif control_right:
            self.losses += 1


def session_top1(row: dict[str, object]) -> bool:
    ranked = row.get("ranked_step_ids") or []
    return bool(ranked) and ranked[0] == row.get("expected_step_id")


def compare_accuracy(control: Arm, variant: Arm) -> dict[str, Paired]:
    results = {"pass_top1": Paired(), "session_top1": Paired(), "check_correct": Paired()}
    for trace_id, variant_row in variant.passes.items():
        control_row = control.passes.get(trace_id)
        if control_row is None:
            continue
        control_outcome, variant_outcome = control_row.get("outcome", {}), variant_row.get("outcome", {})
        # Only passes whose board held the truth can be ranked right or wrong.
        if control_outcome.get("top1_correct") is None or variant_outcome.get("top1_correct") is None:
            continue
        results["pass_top1"].add(bool(control_outcome["top1_correct"]), bool(variant_outcome["top1_correct"]))
    for fixture, variant_row in variant.sessions.items():
        if fixture in control.sessions:
            results["session_top1"].add(session_top1(control.sessions[fixture]), session_top1(variant_row))
    for fixture, variant_row in variant.checks.items():
        if fixture in control.checks:
            control_row = control.checks[fixture]
            results["check_correct"].add(
                control_row["produced_verdict"] == control_row["expected_verdict"],
                variant_row["produced_verdict"] == variant_row["expected_verdict"],
            )
    return results


def latency_ratio(control: Arm, variant: Arm) -> dict[str, float | int | None]:
    ratios = []
    for trace_id, variant_row in variant.passes.items():
        control_row = control.passes.get(trace_id)
        if control_row and control_row.get("latency_ms") and variant_row.get("latency_ms") is not None:
            ratios.append(float(variant_row["latency_ms"]) / float(control_row["latency_ms"]))
    if not ratios:
        return {"pairs": 0, "geometric_mean": None, "median": None}
    geometric = math.exp(sum(math.log(ratio) for ratio in ratios if ratio > 0) / len(ratios))
    return {"pairs": len(ratios), "geometric_mean": geometric, "median": statistics.median(ratios)}


def rate(rows: list[dict[str, object]], predicate) -> float | None:
    return sum(bool(predicate(row)) for row in rows) / len(rows) if rows else None


def insufficient_rate(arm: Arm, fixtures: set[str]) -> float | None:
    return rate([arm.sessions[f] for f in fixtures], lambda row: row.get("certainty") == "insufficient")


def check_false_complete_rate(arm: Arm, fixtures: set[str]) -> float | None:
    negatives = [arm.checks[f] for f in fixtures if arm.checks[f]["expected_verdict"] == "incomplete"]
    return rate(negatives, lambda row: row["produced_verdict"] == "complete")


def slot_histogram(arm: Arm) -> dict[str, dict[str, int]]:
    """How often each slot letter was chosen, beside how often it held the
    truth. A model that favours a position shows a chosen count far above
    its truth count — the §2a slot-B bias check."""
    chosen = {slot: 0 for slot in SLOTS}
    truth = {slot: 0 for slot in SLOTS}
    for row in arm.passes.values():
        outcome = row.get("outcome", {})
        if outcome.get("chosen_slot") in chosen:
            chosen[outcome["chosen_slot"]] += 1
        if outcome.get("truth_slot") in truth:
            truth[outcome["truth_slot"]] += 1
    used = [slot for slot in SLOTS if chosen[slot] or truth[slot]]
    return {"chosen": {slot: chosen[slot] for slot in used}, "truth": {slot: truth[slot] for slot in used}}


def worse(variant: float | None, control: float | None) -> bool:
    return variant is not None and control is not None and variant > control


@dataclass
class Verdict:
    variant: str
    adjusted_p: float
    accuracy: dict[str, Paired]
    latency: dict[str, float | int | None]
    insufficient: tuple[float | None, float | None]
    false_complete: tuple[float | None, float | None]
    notes: list[str] = field(default_factory=list)
    # Which paired accuracy decides: per pass (VLM replays) or per session
    # (geometric recovery, which has no passes).
    primary_level: str = "pass_top1"

    @property
    def decision(self) -> str:
        primary = self.accuracy[self.primary_level]
        regressed = worse(self.insufficient[1], self.insufficient[0]) or worse(self.false_complete[1], self.false_complete[0])
        if regressed:
            return "HOLD (insufficient or false-complete rate rose)"
        unit = "passes" if self.primary_level == "pass_top1" else "sessions"
        if primary.pairs == 0:
            return f"UNMEASURED (no paired {unit} with the truth available)"
        if primary.pairs < MINIMUM_PAIRS:
            return f"UNDERPOWERED ({primary.pairs} paired {unit}; a verdict needs >= {MINIMUM_PAIRS})"
        if primary.wins > primary.losses and self.adjusted_p < ALPHA:
            return "FLIP CANDIDATE: accuracy win (device rows still required)"
        geometric = self.latency.get("geometric_mean")
        if primary.losses == 0 and geometric is not None and geometric <= 1 - LATENCY_NOISE:
            return "FLIP CANDIDATE: no accuracy loss, latency win (device rows still required)"
        return "HOLD"


def compare(control: Arm, variants: list[Arm], primary: str = "pass_top1") -> list[Verdict]:
    accuracies = [compare_accuracy(control, variant) for variant in variants]
    adjusted = holm([accuracy[primary].p_value for accuracy in accuracies])
    verdicts = []
    for variant, accuracy, p in zip(variants, accuracies, adjusted):
        sessions = set(control.sessions) & set(variant.sessions)
        checks = set(control.checks) & set(variant.checks)
        verdicts.append(Verdict(
            variant=variant.name,
            adjusted_p=p,
            accuracy=accuracy,
            latency=latency_ratio(control, variant),
            insufficient=(insufficient_rate(control, sessions), insufficient_rate(variant, sessions)),
            false_complete=(check_false_complete_rate(control, checks), check_false_complete_rate(variant, checks)),
            primary_level=primary,
        ))
    return verdicts


def describe(value: float | None, digits: int = 3) -> str:
    return "-" if value is None else f"{value:.{digits}f}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--variant", type=Path, action="append", required=True)
    parser.add_argument(
        "--primary",
        choices=("pass_top1", "session_top1"),
        default="pass_top1",
        help="the paired accuracy that decides: per replayed pass (VLM arms) or per session "
        "(geometric recovery arms, e.g. SyntheticRGBD --suite recovery)",
    )
    arguments = parser.parse_args(argv)

    control = Arm.load(arguments.control)
    variants = [Arm.load(path) for path in arguments.variant]
    print(f"control {control.name}: slots {slot_histogram(control)}")
    for verdict, variant in zip(compare(control, variants, primary=arguments.primary), variants):
        print(f"\nvariant {verdict.variant}")
        for level, paired in verdict.accuracy.items():
            print(
                f"  {level}: {paired.pairs} pairs, {paired.wins} wins / {paired.losses} losses "
                f"(exact McNemar p={paired.p_value:.4f})"
            )
        print(f"  {arguments.primary} Holm-adjusted p={verdict.adjusted_p:.4f}; with no losses, p < 0.05 needs >= 6 wins")
        latency = verdict.latency
        print(
            f"  latency ratio variant/control over {latency['pairs']} passes: "
            f"geometric mean {describe(latency['geometric_mean'])}, median {describe(latency['median'])} "
            f"(differences under {LATENCY_NOISE:.0%} are noise)"
        )
        print(f"  insufficient rate {describe(verdict.insufficient[0])} -> {describe(verdict.insufficient[1])}")
        print(f"  check false-complete {describe(verdict.false_complete[0])} -> {describe(verdict.false_complete[1])}")
        print(f"  slots {slot_histogram(variant)}")
        print(f"  VERDICT {verdict.decision}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
