from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import phase1_report
from phase1_report import (
    admission_readout,
    load_bundles,
    merged_rows,
    release_split,
)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


def write_ndjson(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))


class Bundles:
    """Hand-written bundles: just the files the report reads."""

    def __init__(self, root: Path) -> None:
        self.root = root

    def bundle(self, name: str, sessions: dict[str, dict[str, object]], device_model: str = "iPhone18,1") -> Path:
        bundle = self.root / name
        write_json(bundle / "evidence_bundle.json", {"device_model": device_model, "session_ids": list(sessions)})
        for session_id, spec in sessions.items():
            directory = bundle / "sessions" / session_id
            write_json(directory / "session.json", {"session_id": session_id, **spec.get("file", {})})
            for name, rows in spec.get("ndjson", {}).items():
                write_ndjson(directory / name, rows)
            for name, value in spec.get("json", {}).items():
                write_json(directory / name, value)
        return bundle


def staged_check(fixture: str, **overrides: object) -> dict[str, object]:
    return {
        "kind": "vlm_check", "schema_version": 1, "fixture_id": fixture, "expected_verdict": "incomplete",
        "produced_verdict": "incomplete", "latency_ms": 5_000, "provenance": "device", "device_model": "iPhone18,1",
        "label_kind": "staged", "physical_case": True, "legal_use_confirmed": True, "authored_model_id": "m1",
        **overrides,
    }


def run_report(bundles: list[Path], work: Path, *extra: str) -> tuple[int, str]:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = phase1_report.main([*map(str, bundles), "--work", str(work), *extra])
    return code, out.getvalue()


class Phase1ReportTests(unittest.TestCase):
    # Every test here fails on the old code with ImportError: there was no
    # tool that read a Phase 1 bundle end to end.
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.bundles = Bundles(self.root)

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_sessions_merge_once_and_synthetic_bundles_are_flagged(self) -> None:
        shared = {"s1": {"ndjson": {"check.ndjson": [staged_check("c1")]}}}
        first = self.bundles.bundle("a", shared)
        second = self.bundles.bundle("b", shared)
        synthetic = self.bundles.bundle("c", {"s9": {}}, device_model="synthetic:bricky-harness")
        loaded = load_bundles([first, second, synthetic])
        self.assertEqual(sorted(session.session_id for session in loaded.sessions), ["s1", "s9"])
        self.assertTrue(any("already read" in warning for warning in loaded.warnings))
        self.assertTrue(any("SYNTHETIC" in warning for warning in loaded.warnings))
        self.assertEqual(len(merged_rows(loaded.sessions)["vlm_check"]), 1)

    def test_release_split_keeps_only_what_the_preflight_accepts(self) -> None:
        rows = {
            "vlm_check": [
                staged_check("ok"),
                staged_check("confirmed", label_kind="confirmed"),
                staged_check("mac", provenance="replay", device_model="replay:Mac14,9"),
            ],
            "verification": [
                {"kind": "verification", "provenance": "device", "device_model": "iPhone18,1", "fixture_id": "w1",
                 "authored_model_id": "m1"},
                {"kind": "verification", "provenance": "device", "device_model": "iPhone18,1", "fixture_id": "w2",
                 "authored_model_id": "m1", "challenge_class": "wrong_colour", "expected_failure": True},
            ],
            "recovery": [
                {"fixture_id": "r1", "physical_case": True, "variant_id": "baseline"},
                {"fixture_id": "r2", "physical_case": True, "variant_id": "prompt=b"},
                {"fixture_id": "r3", "physical_case": None},
            ],
            "shadow_check": [],
        }
        eligible, excluded = release_split(rows)
        self.assertEqual([row["fixture_id"] for row in eligible["vlm_check"]["all"]], ["ok"])
        self.assertEqual([row["fixture_id"] for row in eligible["verification"]["all"]], ["w1"])
        self.assertEqual(sorted(eligible["recovery"]), ["baseline", "prompt=b"])
        self.assertEqual(excluded["vlm_check: has label_kind 'confirmed'; release needs 'staged'"], 1)
        self.assertEqual(excluded["vlm_check: has provenance 'replay'; release needs 'device'"], 1)
        self.assertEqual(excluded["verification: outside the release taxonomy (challenge scenario)"], 1)
        self.assertEqual(excluded["recovery: not a staged physical case"], 1)

    def test_admission_counts_each_load_once_and_masks_an_earlier_peak(self) -> None:
        def session(snapshot: dict[str, object] | None) -> phase1_report.Session:
            return phase1_report.Session(self.root, self.root, {"admission": snapshot} if snapshot else {}, False)
        measured = {"floor_bytes": 5_500_000_000, "warm_up_peak_bytes": 9_000_000_000,
                    "footprint_before_load_bytes": 1_000_000_000, "lifetime_peak_before_load_bytes": 2_000_000_000}
        smaller = dict(measured, warm_up_peak_bytes=6_000_000_000)
        masked = dict(measured, lifetime_peak_before_load_bytes=9_500_000_000)
        unrecorded = {"floor_bytes": 5_500_000_000}
        report = admission_readout([session(measured), session(measured), session(smaller), session(masked),
                                    session(unrecorded), session(None)])
        self.assertEqual(report["unique_snapshots"], 4)
        self.assertEqual((report["measured"], report["masked"], report["unrecorded"]), (2, 1, 1))
        self.assertEqual(report["worst_cost_bytes"], 8_000_000_000)
        self.assertEqual(report["measured_floor_bytes"], 10_000_000_000)
        self.assertEqual(report["recorded_floor_bytes"], [5_500_000_000])

    def test_readouts_from_one_device_bundle(self) -> None:
        window = "W1"
        bundle = self.bundles.bundle("device", {
            "s1": {
                "file": {
                    "staged": {"expected_completed_count": 2}, "physical_build_id": "b-1",
                    "ground_truth": {"kind": "staged"}, "conditions_start": {"thermal_state": "fair"},
                    "recorder_health": {"write_failures": 2, "failed_operations": {"record captures": 2},
                                        "windows_skipped_at_cap": 1, "windows_skipped_low_space": 0},
                },
                "ndjson": {
                    "traces.ndjson": [
                        {"pass": "finalist", "termination": "accepted"},
                        {"pass": "finalist", "termination": "max_tokens_exhausted"},
                        {"pass": "check", "termination": "accepted", "check_geometry": {"delta_box": [0, 0, 1, 1]}},
                    ],
                    "shadow-checks.ndjson": [
                        {"os_build": "27A1", "standalone_outcome": "answered", "latency_ms": 1_000},
                        {"os_build": "27A1", "standalone_outcome": "answered", "latency_ms": 3_000},
                        {"os_build": "27A1", "standalone_outcome": "failed_refusal", "latency_ms": 200},
                        {"os_build": "27A1", "standalone_outcome": "unavailable_model", "latency_ms": 0},
                    ],
                    "check.ndjson": [staged_check("c1")],
                    "diffs.ndjson": [{"window_id": window, "placements": [
                        {"placement": 0, "tallies": [{"offset": [0, 0, 1, 0], "wins_present": 40, "wins_alternative": 2}]},
                        {"placement": 3, "tallies": [{"offset": [0, 0, 1, 0], "wins_present": 4, "wins_alternative": 41}]},
                    ]}],
                },
                "json": {
                    f"windows/{window}.json": {"window_id": window, "detectability": "strong",
                                               "staged": {"scenario": "plate_offset"}, "colour_term": {"mode": "shadow"}},
                    "windows/frames/f1.json": {"colour_encoding": "rgb8_bt709_full", "auxiliary_extract_ms": 1.0,
                                               "segmentation_width": 256, "segmentation_height": 192,
                                               "segmentation_bytes_per_row": 320},
                    "windows/frames/f2.json": {"colour_encoding": "rgb8_bt709_full", "auxiliary_extract_ms": 4.0},
                },
            },
        })
        work = self.root / "work"
        code, output = run_report([bundle], work)
        self.assertEqual(code, 0, output)
        lines = {line.split(" ", 1)[0]: line for line in output.splitlines() if line and line.split(" ", 1)[0].isupper()}
        self.assertIn("rank accepted=1 max_tokens_exhausted=1; check accepted=1", lines["TERMINATION"])
        self.assertIn("runs=4 answered=2 unavailable=1 refused=1 latency p50=", lines["SHADOW_ADVISOR"])
        self.assertIn("thermal=fair:4", lines["SHADOW_ADVISOR"])
        self.assertEqual(lines["COLOUR_ENCODING"], "COLOUR_ENCODING rgb8_bt709_full=2")
        self.assertIn("p95=4.00 ms over 2 window frames", lines["RELAY_AUX_EXTRACT"])
        self.assertEqual(lines["SEGMENTATION"], "SEGMENTATION 256x192/320=1")
        self.assertIn("1 sessions with gaps: 2 failed writes, 1 windows skipped at the cap", lines["RECORDER"])
        self.assertIn("colour_term_windows=1 check_geometry_traces=1", lines["COUNTS"])
        self.assertIn("staged_sessions_with_build_label=1", lines["COUNTS"])
        self.assertIn("ADMISSION UNMEASURED", lines["ADMISSION"])
        self.assertIn("RELEASE vlm_check ACCEPTED (1 rows)", output)
        self.assertIn("RELEASE recovery UNMEASURED (no release-eligible rows)", output)
        # The step's part is the highest-numbered placement tallied.
        self.assertIn("VERTICAL_CONTEST device plate_offset dy=+1 decisive 1/1 strong (evidence 45;", output)
        report = json.loads((work / "phase1_report.json").read_text())
        self.assertEqual(report["vertical_contest"]["plate_offset"]["status"], "UNMEASURED", "no complete controls yet")
        self.assertTrue((work / "rows" / "vlm_check.ndjson").is_file())

    def test_strict_fails_when_a_release_run_is_refused(self) -> None:
        bundle = self.bundles.bundle("device", {"s1": {"ndjson": {"verification.ndjson": [
            {"kind": "verification", "schema_version": 1, "provenance": "device", "device_model": "iPhone18,1",
             "fixture_id": "w1", "authored_model_id": "m1", "expected_verdict": "complete",
             "produced_verdict": "complete", "detectability": "strong", "latency_ms": 900},
        ]}}})
        code, output = run_report([bundle], self.root / "relaxed")
        self.assertEqual(code, 0, output)
        code, output = run_report([bundle], self.root / "strict", "--strict")
        self.assertEqual(code, 1, output)
        self.assertRegex(output, r"RELEASE verification (FAIL|REFUSED) \(1 rows\)")


STUB = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["PHASE1_STUB_LOG"], "a") as log:
    log.write(json.dumps([os.path.basename(sys.argv[0])] + sys.argv[1:]) + "\\n")
if "--out" in sys.argv:
    out = sys.argv[sys.argv.index("--out") + 1]
    open(out, "w").close()
    if sys.argv[1:2] == ["replay"] and "--checks" in sys.argv:
        with open(out + ".traces.ndjson", "w") as traces:
            traces.write(json.dumps({"trace_id": "t1", "matches_device": True}) + "\\n")
            traces.write(json.dumps({"trace_id": "t2", "matches_device": False}) + "\\n")
print("stub ok")
"""


class MacStepTests(unittest.TestCase):
    # Fail on the old code with ImportError, as above.
    CHALLENGE_IDENTITY = "b7e07c10132a29b5b9f227db163982ea8f34e04535002d933ebd77a7e2e5c0d3"

    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.bundles = Bundles(self.root)
        self.log = self.root / "calls.log"
        import os
        self.previous = os.environ.get("PHASE1_STUB_LOG")
        os.environ["PHASE1_STUB_LOG"] = str(self.log)

    def tearDown(self) -> None:
        import os
        if self.previous is None:
            os.environ.pop("PHASE1_STUB_LOG", None)
        else:
            os.environ["PHASE1_STUB_LOG"] = self.previous
        self.directory.cleanup()

    def stub(self, name: str) -> Path:
        path = self.root / "bin" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(STUB)
        path.chmod(0o755)
        return path

    def calls(self) -> list[list[str]]:
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_the_model_identity_is_the_one_syntheticrgbd_computes(self) -> None:
        # Pinned from a bundle SyntheticRGBD --write-bundle wrote for this folder.
        challenge = Path(__file__).resolve().parent.parent / "SyntheticScenes/fixtures/challenge/challenge.ldr"
        self.assertEqual(phase1_report.model_identity(challenge), self.CHALLENGE_IDENTITY)

    def test_without_tools_every_mac_step_is_printed(self) -> None:
        first = self.bundles.bundle("a", {"s1": {}})
        second = self.bundles.bundle("b", {"s2": {}})
        code, output = run_report([first, second], self.root / "work")
        self.assertEqual(code, 0, output)
        self.assertIn(f"NEXT validate a: bricky-harness replay --bundle {first} --dry-run --verify-images", output)
        self.assertIn(f"NEXT lattice-rows: bricky-harness lattice-rows --bundle {first} --bundle {second} --out", output)
        self.assertIn("NEXT geometric control a-MODEL: SyntheticRGBD '<model.ldr>'", output)
        self.assertNotIn("MODEL a:", output, "no --model-ldr given, so nothing to mismatch")
        self.assertEqual(self.calls(), [])

    def test_with_tools_the_steps_run_once_per_bundle_and_model(self) -> None:
        model = self.root / "model" / "tower.ldr"
        model.parent.mkdir()
        model.write_text("0 Tower\n")
        identity = phase1_report.model_identity(model)
        bundle = self.bundles.bundle("a", {"s1": {
            "file": {"instruction_sha256": identity},
            "ndjson": {"traces.ndjson": [{"trace_id": "t1", "termination": "accepted"},
                                         {"trace_id": "t2", "termination": "max_tokens_exhausted"}]},
        }})
        other = self.bundles.bundle("b", {"s2": {"file": {"instruction_sha256": "f" * 64}}})
        harness, tool = self.stub("bricky-harness"), self.stub("SyntheticRGBD")
        code, output = run_report(
            [bundle, other], self.root / "work", "--harness", str(harness), "--model-dir", str(self.root),
            "--model-revision", "abc", "--synthetic-rgbd", str(tool), "--ldraw-root", str(self.root),
            "--model-ldr", str(model),
        )
        self.assertEqual(code, 0, output)
        calls = self.calls()
        replays = [call for call in calls if call[:2] == ["bricky-harness", "replay"] and "--checks" in call]
        self.assertEqual(len(replays), 2)
        lattice = [call for call in calls if call[1:2] == ["lattice-rows"]]
        self.assertEqual(len(lattice), 1)
        self.assertEqual(lattice[0].count("--bundle"), 2)
        synthetic = [call for call in calls if call[0] == "SyntheticRGBD"]
        self.assertEqual(len(synthetic), 6, "windows, two colour arms, stud labels, two geometric arms, bundle a only")
        self.assertTrue(all(call[1] == str(model) for call in synthetic))
        self.assertEqual(sum("--suite" in call for call in synthetic), 2)
        self.assertIn("REPLAY_MATCHES a 1/2 traces match the device; 1/1 where the device's grammar accepted", output)
        self.assertIn("MODEL b: no --model-ldr matches instruction ffffffffffff", output)


if __name__ == "__main__":
    unittest.main()
