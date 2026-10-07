from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from export_training_pairs import PROBE_PREFIX, main, variant_id


def make_bundle(
    root: Path,
    sessions: list[dict[str, object]],
    *,
    device: str = "iPhone18,1",
    name: str = "bundle",
) -> Path:
    """A bundle on disk: each session dict gives its model, build, label and
    traces (`slots`: slot -> step id; `truth` picks the expected step)."""
    bundle = root / name
    bundle.mkdir(parents=True)
    ids = []
    for index, spec in enumerate(sessions):
        session_id = f"{name}-s{index}"
        ids.append(session_id)
        directory = bundle / "sessions" / session_id
        (directory / "boards").mkdir(parents=True)
        traces = []
        for trace_index, slots in enumerate(spec.get("traces", [{"A": "m#2", "B": "m#3"}])):
            trace_id = f"{session_id}-t{trace_index}"
            board = f"boards/{trace_id}.jpg"
            (directory / board).write_bytes(spec.get("image", f"jpeg-{trace_id}").encode())
            row = {
                "trace_id": trace_id, "session_id": session_id, "pass": spec.get("pass", "finalist"),
                "board_relative_path": board, "candidate_step_ids": slots, "prompt": "rank these",
                "schema_json": "{}", "model_revision": "rev",
            }
            if "variant" in spec:
                row["variant"] = spec["variant"]
            traces.append(row)
        (directory / "traces.ndjson").write_text("".join(json.dumps(row) + "\n" for row in traces))
        session = {
            "session_id": session_id,
            "instruction_sha256": spec.get("sha", "sha-0"),
            "authored_model_id": spec.get("amid", f"amid-{spec.get('sha', 'sha-0')}"),
            "device_model": spec.get("device", device),
            "ground_truth": {"kind": spec.get("kind", "staged"), "expected_step_id": spec.get("truth", "m#2")},
            "staged": {"legal_use_confirmed": spec.get("legal", True)},
        }
        if spec.get("build"):
            session["physical_build_id"] = spec["build"]
        (directory / "session.json").write_text(json.dumps(session))
    (bundle / "evidence_bundle.json").write_text(json.dumps({"session_ids": ids}))
    return bundle


def run(*arguments: object) -> tuple[int, str]:
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        code = main([str(argument) for argument in arguments])
    return code, output.getvalue()


def read_jsonl(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text().splitlines()]


def many_models(models: int, per_model: int = 2) -> list[dict[str, object]]:
    return [
        {"sha": f"sha-{model}", "build": f"b-{model}", "image": f"jpeg-{model}-{index}"}
        for model in range(models) for index in range(per_model)
    ]


class ExportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())

    def test_refuses_unlabeled_replay_synthetic_judged(self) -> None:
        sessions = many_models(4) + [
            {"sha": "x1", "kind": "unlabeled"}, {"sha": "x2", "kind": "judged"},
            {"sha": "x3", "device": "replay:Mac14,9"}, {"sha": "x4", "device": "synthetic:bricky-harness"},
            {"sha": "x5", "legal": False}, {"sha": "x6", "truth": "m#9"},
        ]
        bundle = make_bundle(self.root, sessions)
        code, _ = run(bundle, "--out", self.root / "out", "--smoke")
        self.assertEqual(code, 0)
        manifest = json.loads((self.root / "out" / "manifest.json").read_text())
        self.assertEqual(manifest["exclusions"], {
            "label_judged": 1, "label_unlabeled": 1, "no_legal_use": 1, "replay_device": 1, "truth_not_on_board": 1,
        }, "with --smoke, only synthetic devices are let through")
        pairs = read_jsonl(self.root / "out" / "train.jsonl") + read_jsonl(self.root / "out" / "test.jsonl")
        self.assertEqual(len(pairs), 9)
        # Without --smoke, a synthetic device is refused too (and the corpus
        # is far below 150 sessions).
        code, output = run(bundle, "--out", self.root / "real")
        self.assertEqual(code, 2)
        self.assertIn("need 150", output)

    def test_min_labelled_gate(self) -> None:
        code, output = run(make_bundle(self.root, many_models(3)), "--out", self.root / "out")
        self.assertEqual(code, 2)
        self.assertIn("6 labelled sessions with pairs, need 150", output)
        self.assertFalse((self.root / "out" / "train.jsonl").exists())

    def test_a_real_sized_corpus_exports_and_needs_two_components_per_side(self) -> None:
        code, _ = run(make_bundle(self.root, many_models(10, per_model=16), name="ten"), "--out", self.root / "ok")
        self.assertEqual(code, 0)
        split = json.loads((self.root / "ok" / "split_manifest.json").read_text())
        self.assertGreaterEqual(len(split["test"]["components"]), 2)
        self.assertGreaterEqual(len(split["train"]["components"]), 2)
        # 160 sessions of one model and build are one component: nothing is
        # held out at all.
        one = [{"sha": "only", "build": "b", "image": f"jpeg-{index}"} for index in range(160)]
        code, output = run(make_bundle(self.root, one, name="one"), "--out", self.root / "no")
        self.assertEqual(code, 2)
        self.assertIn("components", output)

    def test_split_groups_by_model_and_build_transitively(self) -> None:
        # Model A and model B share a physical build (b-shared), and model B
        # and model C share an authored-model id: all three are one component.
        sessions = [
            {"sha": "A", "amid": "amid-A", "build": "b-shared"},
            {"sha": "B", "amid": "amid-BC", "build": "b-shared"},
            {"sha": "C", "amid": "amid-BC", "build": "b-c"},
            {"sha": "D", "build": "b-d"}, {"sha": "E", "build": "b-e"}, {"sha": "F", "build": "b-f"},
        ]
        code, _ = run(make_bundle(self.root, sessions), "--out", self.root / "out", "--smoke", "--test-fraction", "0.5")
        self.assertEqual(code, 0)
        train = read_jsonl(self.root / "out" / "train.jsonl")
        test = read_jsonl(self.root / "out" / "test.jsonl")
        side = {pair["instruction_sha256"]: name for name, pairs in (("train", train), ("test", test)) for pair in pairs}
        self.assertEqual(side["A"], side["B"])
        self.assertEqual(side["B"], side["C"])

    def test_split_deterministic(self) -> None:
        bundle = make_bundle(self.root, many_models(8))
        for out in ("one", "two"):
            self.assertEqual(run(bundle, "--out", self.root / out, "--smoke", "--seed", "3")[0], 0)
        for name in ("train.jsonl", "test.jsonl", "split_manifest.json"):
            self.assertEqual((self.root / "one" / name).read_text(), (self.root / "two" / name).read_text(), name)
        run(bundle, "--out", self.root / "other", "--smoke", "--seed", "4")
        self.assertTrue(
            any((self.root / "one" / name).read_text() != (self.root / "other" / name).read_text()
                for name in ("train.jsonl", "test.jsonl")),
            "a different seed should be able to choose a different split",
        )

    def test_no_leakage(self) -> None:
        # The same board image in two models' sessions would put one picture
        # on both sides: refused.
        sessions = many_models(6) + [{"sha": "dup-1", "image": "same"}, {"sha": "dup-2", "image": "same"}]
        code, output = run(
            make_bundle(self.root, sessions), "--out", self.root / "out", "--smoke",
            "--test-fraction", "0.01", "--holdout-sha", "dup-2",
        )
        self.assertEqual(code, 2)
        self.assertIn("image_sha256=", output)
        manifest = json.loads((self.root / "out" / "manifest.json").read_text())
        self.assertEqual(len(manifest["leakage"]["violations"]), 1)
        clean = make_bundle(self.root, many_models(6), name="clean")
        self.assertEqual(run(clean, "--out", self.root / "clean-out", "--smoke")[0], 0)
        self.assertEqual(json.loads((self.root / "clean-out" / "manifest.json").read_text())["leakage"]["violations"], [])

    def test_target_starts_with_probe_prefix(self) -> None:
        sessions = [{"sha": f"s{index}", "traces": [{"A": "m#1", "B": "m#2", "C": "m#3"}]} for index in range(4)]
        run(make_bundle(self.root, sessions), "--out", self.root / "out", "--smoke")
        pairs = read_jsonl(self.root / "out" / "train.jsonl") + read_jsonl(self.root / "out" / "test.jsonl")
        for pair in pairs:
            self.assertEqual(pair["truth_slot"], "B")
            self.assertTrue(pair["target_text"].startswith(pair["probe_prefix"]))
            self.assertEqual(pair["target_text"], PROBE_PREFIX + 'B"]}')
            self.assertEqual(json.loads(pair["target_text"]), {"status": "matched", "ranking": ["B"]})
            self.assertEqual(pair["slot_count"], 3)

    def test_smoke_marks_every_pair(self) -> None:
        sessions = [dict(spec, device="synthetic:bricky-harness") for spec in many_models(4)]
        self.assertEqual(run(make_bundle(self.root, sessions), "--out", self.root / "out", "--smoke")[0], 0)
        pairs = read_jsonl(self.root / "out" / "train.jsonl") + read_jsonl(self.root / "out" / "test.jsonl")
        self.assertTrue(pairs)
        self.assertTrue(all(pair["smoke"] for pair in pairs))
        self.assertTrue(json.loads((self.root / "out" / "manifest.json").read_text())["smoke"])

    def test_checks_and_other_variants_are_not_pairs(self) -> None:
        sessions = many_models(4) + [
            {"sha": "chk", "pass": "check"},
            {"sha": "probe", "variant": {"scoring": "probe"}},
        ]
        run(make_bundle(self.root, sessions), "--out", self.root / "out", "--smoke")
        manifest = json.loads((self.root / "out" / "manifest.json").read_text())
        self.assertEqual(manifest["exclusions"], {"other_variant": 1})
        self.assertEqual(manifest["pairs"]["train"] + manifest["pairs"]["test"], 8)

    def test_variant_ids_mirror_swift(self) -> None:
        self.assertEqual(variant_id(None), "baseline")
        self.assertEqual(variant_id({"decode": "legacy", "image_side": 1024}), "baseline")
        self.assertEqual(variant_id({"decode": "feed_all", "vote": "borda_legacy"}), "decode=feed_all,vote=borda_legacy")
        self.assertEqual(
            variant_id({"scoring": "probe", "adapter": "first-slot.v1@0123456789ab"}),
            "scoring=probe,adapter=first-slot.v1@0123456789ab",
        )
        self.assertEqual(
            variant_id({"slot_order": "rotated", "board_layout": "v2", "labels": "slot", "prompt_style": "dynamic_range",
                        "image_side": 768}),
            "slot_order=rotated,board=v2,labels=slot,prompt=dynamic_range,image_side=768",
        )

    def test_copy_images_rewrites_paths(self) -> None:
        run(make_bundle(self.root, many_models(4)), "--out", self.root / "out", "--smoke", "--copy-images")
        for pair in read_jsonl(self.root / "out" / "train.jsonl"):
            self.assertEqual(pair["image_path"], f"images/{pair['image_sha256']}.jpg")
            self.assertTrue((self.root / "out" / pair["image_path"]).exists())


if __name__ == "__main__":
    unittest.main()
