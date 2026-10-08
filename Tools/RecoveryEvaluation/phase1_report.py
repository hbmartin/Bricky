#!/usr/bin/env python3
"""Phase 1 report: every readout a set of exported evidence bundles gives.

Reads one or more unzipped bundles (docs/PHASE1_RUNBOOK.md) and, in one run:

- merges each session's device rows (`benchmark`, `check`, `verification`,
  `shadow_check`) by kind, counting a session exported twice once;
- scores each kind in release mode in its own run, on the rows the release
  preflight would accept, never requiring registration rows (the device
  makes none), then all rows together informationally;
- prints the readouts no other tool computes, one greppable line each:
  TERMINATION, ADMISSION, SHADOW_ADVISOR, COLOUR_ENCODING, RELAY_AUX_EXTRACT,
  SEGMENTATION, RECORDER, COUNTS and the device VERTICAL_CONTEST.

Everything also goes to <work>/phase1_report.json. Standard library only;
safe under `python3 -I`.
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import score_results as scorer  # noqa: E402
from export_training_pairs import contained  # noqa: E402

# A bundle `bricky-harness synth-bundle` or `SyntheticRGBD --write-bundle`
# wrote: pipeline evidence, never release rows.
SYNTHETIC_PREFIX = "synthetic:"
# Per-session device rows, by the kind the scorer reads them as.
ROW_FILES = {
    "recovery": "benchmark.ndjson",
    scorer.VLM_CHECK_KIND: "check.ndjson",
    "verification": "verification.ndjson",
    scorer.SHADOW_CHECK_KIND: "shadow_check.ndjson",
}
RELEASE_KINDS = ("recovery", "verification", scorer.VLM_CHECK_KIND, scorer.SHADOW_CHECK_KIND)
# ADR 0003: the admission floor is the worst measured model cost plus 25%.
ADMISSION_HEADROOM = 1.25
GB = 1_000_000_000


@dataclass
class Session:
    bundle: Path
    directory: Path
    file: dict[str, object]
    synthetic: bool

    @property
    def session_id(self) -> str:
        return str(self.file.get("session_id"))


@dataclass
class Loaded:
    sessions: list[Session] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def read_json(path: Path) -> object | None:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def read_ndjson(path: Path) -> list[dict[str, object]]:
    if not path.is_file():
        return []
    rows = []
    for line in path.read_text().splitlines():
        if line.strip():
            row = json.loads(line)
            if isinstance(row, dict):
                rows.append(row)
    return rows


def load_bundles(bundles: list[Path]) -> Loaded:
    loaded = Loaded()
    seen: set[str] = set()
    for bundle in bundles:
        manifest = read_json(bundle / "evidence_bundle.json")
        if not isinstance(manifest, dict):
            loaded.warnings.append(f"{bundle}: no readable evidence_bundle.json; skipped")
            continue
        synthetic = str(manifest.get("device_model", "")).startswith(SYNTHETIC_PREFIX)
        if synthetic:
            loaded.warnings.append(f"{bundle}: SYNTHETIC bundle ({manifest.get('device_model')}); kept out of release runs")
        root = bundle / "sessions"
        for session_id in manifest.get("session_ids", []):
            directory = root / str(session_id)
            if not contained(root, bundle) or not contained(directory, root):
                loaded.warnings.append(f"{bundle}: session {session_id} resolves outside the bundle; skipped")
                continue
            file = read_json(directory / "session.json")
            if not isinstance(file, dict):
                loaded.warnings.append(f"{bundle}: session {session_id} has no readable session.json; skipped")
                continue
            key = str(file.get("session_id", session_id))
            if key in seen:
                loaded.warnings.append(f"{bundle}: session {key} was already read from another bundle; counted once")
                continue
            seen.add(key)
            loaded.sessions.append(Session(bundle, directory, file, synthetic))
    return loaded


# --- Rows and release splitting ---------------------------------------------


def merged_rows(sessions: list[Session]) -> dict[str, list[dict[str, object]]]:
    rows: dict[str, list[dict[str, object]]] = {kind: [] for kind in ROW_FILES}
    for session in sessions:
        for kind, name in ROW_FILES.items():
            for row in read_ndjson(session.directory / name):
                rows[kind].append(row if kind != "recovery" else {**row, "kind": "recovery"})
    return rows


def informational_rows(rows: dict[str, list[dict[str, object]]]) -> list[dict[str, object]]:
    """Every row, with the staged scenarios outside the release taxonomy
    (rotated, wrong colour, plate offset) scored as challenge rows, so an
    expected wrong-colour failure is not counted as a verification miss."""
    out: list[dict[str, object]] = []
    for kind, kind_rows in rows.items():
        for row in kind_rows:
            if kind == "verification" and row.get("challenge_class"):
                out.append({**row, "kind": scorer.CHALLENGE_KIND, "expected_failure": bool(row.get("expected_failure"))})
            else:
                out.append(row)
    return out


def refusal(check, row: dict[str, object]) -> str | None:
    """The release preflight's own reason for refusing `row`, or None."""
    try:
        check(row)
    except SystemExit as refused:
        return str(refused.code).split(" row 1 ", 1)[-1]
    return None


def release_split(
    rows: dict[str, list[dict[str, object]]]
) -> tuple[dict[str, dict[str, list[dict[str, object]]]], Counter[str]]:
    """Release-eligible rows by kind and arm, and why the others were left out.
    Rows are judged one at a time by the scorer's own validators, so the rules
    cannot drift; corpus-level rules (model count, variety) stay with the run.
    Pass rows from device bundles only."""
    eligible: dict[str, dict[str, list[dict[str, object]]]] = {kind: {} for kind in RELEASE_KINDS}
    excluded: Counter[str] = Counter()

    def keep(kind: str, row: dict[str, object], arm: str = "all") -> None:
        eligible[kind].setdefault(arm, []).append(row)

    for kind in RELEASE_KINDS:
        for row in rows.get(kind, []):
            if kind == "recovery":
                if row.get("physical_case") is not True:
                    excluded["recovery: not a staged physical case"] += 1
                    continue
                keep(kind, row, str(row.get("variant_id") or "baseline"))
                continue
            if kind == "verification" and any(field in row for field in scorer.NON_RELEASE_FIELDS):
                excluded["verification: outside the release taxonomy (challenge scenario)"] += 1
                continue
            if kind == "verification":
                reason = refusal(lambda one: scorer.validate_triad_release([one], "verification"), row)
            else:
                reason = refusal(lambda one, kind=kind: scorer.validate_vlm_check_release([one], kind=kind), row)
            if reason:
                excluded[f"{kind}: {reason}"] += 1
            else:
                keep(kind, row)
    return eligible, excluded


def write_ndjson(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows))


def run_scorer(path: Path, *arguments: str) -> tuple[int, str]:
    completed = subprocess.run(
        [sys.executable, "-I", str(HERE / "score_results.py"), str(path), *arguments],
        capture_output=True, text=True, check=False,
    )
    return completed.returncode, completed.stdout + completed.stderr


def score_lines(output: str) -> list[str]:
    """The scorer's readout lines, without its JSON report."""
    lines = []
    for line in output.splitlines():
        if line.startswith("{"):
            break
        if line.strip():
            lines.append(line)
    return lines


def release_runs(
    eligible: dict[str, dict[str, list[dict[str, object]]]], work: Path
) -> dict[str, dict[str, object]]:
    results: dict[str, dict[str, object]] = {}
    for kind in RELEASE_KINDS:
        if not eligible[kind]:
            results[kind] = {"status": scorer.UNMEASURED, "rows": 0}
            print(f"RELEASE {kind} {scorer.UNMEASURED} (no release-eligible rows)")
            continue
        for arm, arm_rows in sorted(eligible[kind].items()):
            name = kind if arm == "all" else f"{kind}[{arm}]"
            path = work / "release" / f"{kind}{'' if arm == 'all' else '-' + arm.replace('/', '_')}.ndjson"
            write_ndjson(path, arm_rows)
            code, output = run_scorer(path, "--require-kinds", kind)
            lines = score_lines(output)
            if code != 0:
                # A preflight refusal exits before any gate is judged.
                status = "FAIL" if any(line.startswith(("GATE ", "KIND ")) for line in lines) else "REFUSED"
            else:
                # The check kinds' gates are informational: accepted rows
                # count toward ADR 0018, they do not pass anything.
                status = "ACCEPTED" if kind in scorer.PRESENCE_ONLY_KINDS else "PASS"
            detail = lines[-1] if status == "REFUSED" and lines else ""
            print(f"RELEASE {name} {status} ({len(arm_rows)} rows){' ' + detail if detail else ''}")
            results[name] = {"status": status, "rows": len(arm_rows), "output": lines}
    return results


# --- Readouts ---------------------------------------------------------------


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def termination_readout(sessions: list[Session]) -> dict[str, dict[str, int]]:
    """How generation ended, rank passes apart from step checks. Effectively
    every rank trace should be `accepted` (NEXT_STEPS §1 item 2)."""
    tally: dict[str, Counter[str]] = {"rank": Counter(), "check": Counter()}
    for session in sessions:
        for row in read_ndjson(session.directory / "traces.ndjson"):
            group = "check" if row.get("pass") == "check" else "rank"
            tally[group][str(row.get("termination", "unrecorded"))] += 1
    return {group: dict(sorted(counts.items())) for group, counts in tally.items()}


def admission_readout(sessions: list[Session]) -> dict[str, object]:
    """ADR 0003's floor: the worst measured model cost plus 25%. A cost is
    the warm-up peak less the footprint before load, counted only when the
    warm-up peak rose above every earlier peak (otherwise the lifetime peak
    is not this model's, and the sample is masked). Mirrors
    AdmissionSnapshot.modelPeakCostBytes. One model load is copied into every
    session opened while it lives, so identical snapshots count once."""
    unique: dict[str, dict[str, object]] = {}
    for session in sessions:
        snapshot = session.file.get("admission")
        if isinstance(snapshot, dict):
            unique.setdefault(json.dumps(snapshot, sort_keys=True), snapshot)
    costs: list[int] = []
    masked = unrecorded = 0
    floors = set()
    for snapshot in unique.values():
        floors.add(snapshot.get("floor_bytes"))
        peak = snapshot.get("warm_up_peak_bytes")
        before = snapshot.get("footprint_before_load_bytes")
        peak_before = snapshot.get("lifetime_peak_before_load_bytes")
        if not all(isinstance(value, int) for value in (peak, before, peak_before)):
            unrecorded += 1
        elif peak > peak_before:
            costs.append(peak - before)
        else:
            masked += 1
    worst = max(costs) if costs else None
    return {
        "sessions_with_snapshot": sum(isinstance(session.file.get("admission"), dict) for session in sessions),
        "unique_snapshots": len(unique),
        "measured": len(costs),
        "masked": masked,
        "unrecorded": unrecorded,
        "worst_cost_bytes": worst,
        "measured_floor_bytes": round(worst * ADMISSION_HEADROOM) if worst is not None else None,
        "recorded_floor_bytes": sorted(value for value in floors if isinstance(value, int)),
    }


def shadow_readout(sessions: list[Session]) -> dict[str, dict[str, object]]:
    """The Foundation Models advisor's availability, refusals and latency,
    per OS build (ADR 0018 is re-run per build), with the thermal state the
    sessions opened in."""
    by_build: dict[str, dict[str, object]] = {}
    for session in sessions:
        traces = read_ndjson(session.directory / "shadow-checks.ndjson")
        thermal = (session.file.get("conditions_start") or {}).get("thermal_state", "unrecorded")
        for trace in traces:
            build = str(trace.get("os_build") or session.file.get("os_build") or "unrecorded")
            entry = by_build.setdefault(build, {"outcomes": Counter(), "latencies": [], "thermal": Counter()})
            entry["outcomes"][str(trace.get("standalone_outcome", "unrecorded"))] += 1
            entry["thermal"][str(thermal)] += 1
            if trace.get("standalone_outcome") == "answered" and isinstance(trace.get("latency_ms"), (int, float)):
                entry["latencies"].append(float(trace["latency_ms"]))
    report = {}
    for build, entry in sorted(by_build.items()):
        outcomes: Counter[str] = entry["outcomes"]
        report[build] = {
            "runs": sum(outcomes.values()),
            "answered": outcomes.get("answered", 0),
            "unavailable": outcomes.get("unavailable_model", 0),
            "refused": sum(count for outcome, count in outcomes.items() if outcome.startswith("failed_")),
            "outcomes": dict(sorted(outcomes.items())),
            "latency_p50_ms": percentile(entry["latencies"], 0.5),
            "latency_p95_ms": percentile(entry["latencies"], 0.95),
            "thermal_at_start": dict(sorted(entry["thermal"].items())),
        }
    return report


def window_frames(session: Session) -> list[dict[str, object]]:
    directory = session.directory / "windows" / "frames"
    if not directory.is_dir():
        return []
    frames = []
    for path in sorted(directory.glob("*.json")):
        frame = read_json(path)
        if isinstance(frame, dict):
            frames.append(frame)
    return frames


def windows(session: Session) -> list[dict[str, object]]:
    directory = session.directory / "windows"
    if not directory.is_dir():
        return []
    records = []
    for path in sorted(directory.glob("*.json")):
        record = read_json(path)
        if isinstance(record, dict):
            records.append(record)
    return records


def frame_readouts(sessions: list[Session]) -> dict[str, object]:
    """What the evidence window frames say about the relay (§1a items 2, 8)."""
    encodings: Counter[str] = Counter()
    shapes: Counter[str] = Counter()
    extract: list[float] = []
    for session in sessions:
        for frame in window_frames(session):
            if frame.get("colour_encoding"):
                encodings[str(frame["colour_encoding"])] += 1
            if isinstance(frame.get("auxiliary_extract_ms"), (int, float)):
                extract.append(float(frame["auxiliary_extract_ms"]))
            if frame.get("segmentation_width") is not None:
                shapes[f"{frame['segmentation_width']}x{frame.get('segmentation_height')}"
                       f"/{frame.get('segmentation_bytes_per_row')}"] += 1
    return {
        "colour_encodings": dict(sorted(encodings.items())),
        "auxiliary_extract_frames": len(extract),
        "auxiliary_extract_p50_ms": percentile(extract, 0.5),
        "auxiliary_extract_p95_ms": percentile(extract, 0.95),
        "segmentation_shapes": dict(sorted(shapes.items())),
    }


def recorder_readout(sessions: list[Session]) -> dict[str, object]:
    totals: Counter[str] = Counter()
    operations: Counter[str] = Counter()
    affected = 0
    at_cap_without_health = 0
    for session in sessions:
        health = session.file.get("recorder_health")
        if isinstance(health, dict):
            affected += 1
            for key in ("write_failures", "windows_skipped_at_cap", "windows_skipped_low_space"):
                totals[key] += int(health.get(key) or 0)
            operations.update({str(name): int(count) for name, count in (health.get("failed_operations") or {}).items()})
        # Older sessions record no health: exactly the cap may mean windows
        # were dropped without a count.
        elif len(windows(session)) == 48:
            at_cap_without_health += 1
    return {
        "sessions_with_gaps": affected,
        **{key: totals[key] for key in ("write_failures", "windows_skipped_at_cap", "windows_skipped_low_space")},
        "failed_operations": dict(sorted(operations.items())),
        "sessions_at_cap_without_health": at_cap_without_health,
    }


def count_readouts(sessions: list[Session]) -> dict[str, int]:
    """Collection progress for the checklist items without a scorer."""
    colour_windows = check_geometry = lattice_staged = staged_sessions = labelled = labelled_sessions = 0
    for session in sessions:
        staged = session.file.get("staged") is not None
        staged_sessions += staged
        labelled += staged and bool(session.file.get("physical_build_id"))
        truth = session.file.get("ground_truth") or {}
        labelled_sessions += truth.get("kind") in {"staged", "confirmed"}
        for record in windows(session):
            colour_windows += record.get("colour_term") is not None
            scenario = (record.get("staged") or {}).get("scenario")
            lattice_staged += scenario in {"complete", "shifted_one_stud"}
        check_geometry += sum(
            row.get("check_geometry") is not None for row in read_ndjson(session.directory / "traces.ndjson")
        )
    return {
        "colour_term_windows": colour_windows,
        "check_geometry_traces": check_geometry,
        "lattice_staged_windows": lattice_staged,
        "staged_sessions": staged_sessions,
        "staged_sessions_with_build_label": labelled,
        "labelled_sessions": labelled_sessions,
    }


def device_vertical_contest(sessions: list[Session]) -> dict[str, object]:
    """The build diff's raised-plate contest on staged device windows
    (§1a item 16): `plate_offset` windows, raised by protocol, against
    `complete` windows. Single-part steps: the step's part is the
    highest-numbered placement the diff tallied."""
    rows = []
    for session in sessions:
        scenarios = {
            str(record.get("window_id")): (record.get("staged") or {}).get("scenario")
            for record in windows(session)
        }
        detectability = {str(record.get("window_id")): record.get("detectability") for record in windows(session)}
        latest: dict[str, dict[str, object]] = {}
        for record in read_ndjson(session.directory / "diffs.ndjson"):
            latest[str(record.get("window_id"))] = record
        for window_id, record in latest.items():
            scenario = scenarios.get(window_id)
            if scenario not in {"plate_offset", "complete"}:
                continue
            tallied = [placement for placement in record.get("placements") or [] if placement.get("tallies")]
            if not tallied:
                continue
            part = max(tallied, key=lambda placement: int(placement.get("placement", -1)))
            rows.append({
                "challenge_class": scenario, "detectability": detectability.get(window_id), "tallies": part["tallies"],
            })
    return scorer.vertical_contest_report(
        rows, targets={"plate_offset": scorer.PLATE_UP_OFFSET}, controls=("complete",)
    )


def format_bytes(value: int | None) -> str:
    return "-" if value is None else f"{value / GB:.2f} GB"


def readout_lines(report: dict[str, object]) -> list[str]:
    lines = []
    termination = report["termination"]
    lines.append("TERMINATION " + "; ".join(
        f"{group} " + (" ".join(f"{name}={count}" for name, count in counts.items()) or "none")
        for group, counts in termination.items()
    ))
    admission = report["admission"]
    if admission["measured"]:
        lines.append(
            f"ADMISSION worst cost {format_bytes(admission['worst_cost_bytes'])} -> floor "
            f"{format_bytes(admission['measured_floor_bytes'])} (cost x {ADMISSION_HEADROOM}); recorded floor "
            f"{', '.join(format_bytes(value) for value in admission['recorded_floor_bytes']) or '-'}; "
            f"{admission['measured']} measured, {admission['masked']} masked, {admission['unrecorded']} unrecorded "
            f"of {admission['unique_snapshots']} unique snapshots"
        )
    else:
        lines.append(
            f"ADMISSION {scorer.UNMEASURED} ({admission['masked']} masked, {admission['unrecorded']} unrecorded "
            f"of {admission['unique_snapshots']} unique snapshots; profile in a fresh process: launch, start AR, then load)"
        )
    if report["shadow_advisor"]:
        for build, entry in report["shadow_advisor"].items():
            lines.append(
                f"SHADOW_ADVISOR {build} runs={entry['runs']} answered={entry['answered']} "
                f"unavailable={entry['unavailable']} refused={entry['refused']} "
                f"latency p50={scorer.format_number(entry['latency_p50_ms'])} p95={scorer.format_number(entry['latency_p95_ms'])} ms "
                f"thermal={','.join(f'{name}:{count}' for name, count in entry['thermal_at_start'].items())}"
            )
    else:
        lines.append(f"SHADOW_ADVISOR {scorer.UNMEASURED}")
    frames = report["frames"]
    lines.append("COLOUR_ENCODING " + (" ".join(f"{name}={count}" for name, count in frames["colour_encodings"].items()) or scorer.UNMEASURED))
    if frames["auxiliary_extract_frames"]:
        lines.append(
            f"RELAY_AUX_EXTRACT p50={frames['auxiliary_extract_p50_ms']:.2f} p95={frames['auxiliary_extract_p95_ms']:.2f} ms "
            f"over {frames['auxiliary_extract_frames']} window frames (budget p95 <= 3 ms)"
        )
    else:
        lines.append(f"RELAY_AUX_EXTRACT {scorer.UNMEASURED}")
    lines.append("SEGMENTATION " + (" ".join(f"{shape}={count}" for shape, count in frames["segmentation_shapes"].items()) or scorer.UNMEASURED))
    recorder = report["recorder"]
    lines.append(
        f"RECORDER {recorder['sessions_with_gaps']} sessions with gaps: {recorder['write_failures']} failed writes, "
        f"{recorder['windows_skipped_at_cap']} windows skipped at the cap, {recorder['windows_skipped_low_space']} for low space; "
        f"{recorder['sessions_at_cap_without_health']} older sessions sit at the 48-window cap"
    )
    lines.append("COUNTS " + " ".join(f"{name}={count}" for name, count in report["counts"].items()))
    lines.extend(
        line.replace("VERTICAL_CONTEST", "VERTICAL_CONTEST device", 1)
        for line in scorer.vertical_contest_lines(report["vertical_contest"])
    )
    return lines


def build_report(bundles: list[Path], work: Path) -> tuple[dict[str, object], list[str]]:
    loaded = load_bundles(bundles)
    for warning in loaded.warnings:
        print(f"warning: {warning}")
    device = [session for session in loaded.sessions if not session.synthetic]
    synthetic_ids = {session.session_id for session in loaded.sessions if session.synthetic}
    rows = merged_rows(loaded.sessions)
    for kind, kind_rows in rows.items():
        write_ndjson(work / "rows" / f"{kind}.ndjson", kind_rows)
    eligible, excluded = release_split(merged_rows(device))
    print(
        f"SESSIONS {len(loaded.sessions)} ({len(synthetic_ids)} synthetic) from {len(bundles)} bundles; rows "
        + " ".join(f"{kind}={len(kind_rows)}" for kind, kind_rows in rows.items())
    )
    for reason, count in sorted(excluded.items()):
        print(f"EXCLUDED {count} {reason}")
    report: dict[str, object] = {
        "sessions": len(loaded.sessions),
        "synthetic_sessions": len(synthetic_ids),
        "warnings": loaded.warnings,
        "rows": {kind: len(kind_rows) for kind, kind_rows in rows.items()},
        "excluded": dict(sorted(excluded.items())),
    }
    report["release"] = release_runs(eligible, work)
    everything = informational_rows(rows)
    if everything:
        path = work / "rows" / "all.ndjson"
        write_ndjson(path, everything)
        code, output = run_scorer(path, "--informational", "--allow-mixed-arms")
        report["informational"] = {"exit": code, "output": score_lines(output)}
        for line in score_lines(output):
            print(f"INFORMATIONAL {line}")
    report["termination"] = termination_readout(device)
    report["admission"] = admission_readout(device)
    report["shadow_advisor"] = shadow_readout(device)
    report["frames"] = frame_readouts(device)
    report["recorder"] = recorder_readout(device)
    report["counts"] = count_readouts(device)
    report["vertical_contest"] = device_vertical_contest(device)
    lines = readout_lines(report)
    for line in lines:
        print(line)
    return report, lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("bundles", type=Path, nargs="+", metavar="BUNDLE", help="unzipped evidence bundle directories")
    parser.add_argument("--work", type=Path, required=True, help="where merged rows and phase1_report.json go")
    parser.add_argument("--strict", action="store_true", help="exit 1 when any release run failed or was refused")
    arguments = parser.parse_args(argv)
    arguments.work.mkdir(parents=True, exist_ok=True)
    report, _ = build_report(arguments.bundles, arguments.work)
    (arguments.work / "phase1_report.json").write_text(json.dumps(report, indent=2, sort_keys=True, default=str) + "\n")
    print(f"wrote {arguments.work / 'phase1_report.json'}")
    failed = any(entry.get("status") in {"FAIL", "REFUSED"} for entry in report["release"].values())
    return 1 if arguments.strict and failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
