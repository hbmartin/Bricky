#!/usr/bin/env python3
"""End-to-end smoke of the LoRA pipeline (ADR 0019): synthetic bundle ->
export -> template -> train -> convert -> Swift replays -> Python scoring ->
parity. Nothing it trains is ever used; it proves the plumbing.

    uv run python run_smoke.py --model-dir model --work /tmp/smoke

It needs the pinned weights and a built harness
(`swift build --package-path Packages/RecoveryMLX`). It asserts:
  (a) the converted adapter loads in Swift (refused if any layer, tensor,
      scale or dtype is wrong);
  (b) Swift applies the converted adapter as Python does (parity_check.py):
      its changes to the slot log-odds follow Python's, and a canary at twice
      the scale is clearly stronger, so a scale mix-up would show. Both are
      measured on the adapter converted at 0.02 of its scale, the linear
      regime: the trained one moves log-odds by ~10 nats, where doubling the
      scale no longer doubles the effect. Python trains and scores with the
      device's vision activation (common.match_device), so the transfer
      slope (how strong Swift's effect is against Python's) should be near 1.
      It is reported, not gated: ADR 0019 requires it in [0.9, 1.1] before
      real training;
  (c) a zero-B adapter reproduces the baseline replay exactly (both replays
      warm up first, as the app does: the first call after a load is not
      bit-reproducible).
It also reports held-out first-slot accuracy with the full-strength adapter.
It writes <work>/smoke_report.json.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
PINNED_REVISION = "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b"
# Parity runs on the adapter at 0.02 of its scale, in the linear regime:
# at 0.1 its effect already saturates (3.4x the 0.02 effect, not 5x).
PARITY_SCALE = 0.02


def run(command: list[object], log: Path) -> None:
    printable = " ".join(str(part) for part in command)
    print(f"$ {printable}", flush=True)
    with log.open("w") as handle:
        result = subprocess.run([str(part) for part in command], stdout=handle, stderr=subprocess.STDOUT, check=False)
    if result.returncode != 0:
        raise SystemExit(f"failed ({result.returncode}): {printable}\n{log.read_text()[-2000:]}")


def traces(path: Path) -> dict[str, dict[str, object]]:
    return {row["trace_id"]: row for row in map(json.loads, Path(f"{path}.traces.ndjson").read_text().splitlines())}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True, help="a new, empty working directory")
    parser.add_argument("--harness", type=Path, default=REPO / "Packages/RecoveryMLX/.build/debug/bricky-harness")
    parser.add_argument("--iters", type=int, default=30)
    parser.add_argument("--seed", type=int, default=7)
    arguments = parser.parse_args(argv)
    work, harness, model = arguments.work, arguments.harness, arguments.model_dir
    if not harness.exists():
        raise SystemExit(f"{harness} is missing; swift build --package-path Packages/RecoveryMLX")
    work.mkdir(parents=True, exist_ok=False)
    logs = work / "logs"
    logs.mkdir()
    python = sys.executable
    revision = PINNED_REVISION

    run([harness, "synth-bundle", "--out", work / "bundle", "--seed", arguments.seed], logs / "synth.log")
    run([python, REPO / "Tools/RecoveryEvaluation/export_training_pairs.py", work / "bundle", "--out", work / "pairs",
         "--smoke", "--seed", arguments.seed], logs / "export.log")
    run([harness, "adapter-template", "--model-dir", model, "--model-revision", revision, "--out", work / "zero-b"],
        logs / "template.log")
    run([python, HERE / "train_lora.py", "--model-dir", model, "--pairs", work / "pairs", "--out", work / "trained",
         "--smoke", "--iters", arguments.iters, "--seed", arguments.seed], logs / "train.log")
    template = work / "zero-b" / "template.json"
    for name, extra in (
        ("swift", []),
        ("parity", ["--scale-multiplier", str(PARITY_SCALE)]),
        ("canary", ["--scale-multiplier", str(2 * PARITY_SCALE)]),
    ):
        run([python, HERE / "convert_adapter.py", "--input", work / "trained", "--template", template,
             "--out", work / name, "--name", f"smoke-{name}", "--base-revision", revision, "--smoke", *extra],
            logs / f"convert-{name}.log")

    replays = {"base": [], "parity": ["--adapter", work / "parity"], "canary": ["--adapter", work / "canary"],
               "zero_b": ["--adapter", work / "zero-b"]}
    for arm, extra in replays.items():
        run([harness, "replay", "--bundle", work / "bundle", "--model-dir", model, "--model-revision", revision,
             "--scoring", "probe", "--out", work / f"swift-{arm}.ndjson", *extra], logs / f"replay-{arm}.log")
    for arm, extra in (
        ("base", []), ("parity", ["--adapter", work / "parity"]), ("full", ["--adapter", work / "swift"]),
    ):
        run([python, HERE / "eval_first_slot.py", "--model-dir", model, "--pairs", work / "pairs", "--split", "test",
             "--out", work / f"python-{arm}.jsonl", *extra], logs / f"eval-{arm}.log")

    parity = subprocess.run([
        python, HERE / "parity_check.py",
        "--python-base", work / "python-base.jsonl", "--python-adapter", work / "python-parity.jsonl",
        "--swift-base", work / "swift-base.ndjson.traces.ndjson",
        "--swift-adapter", work / "swift-parity.ndjson.traces.ndjson",
        "--swift-canary", work / "swift-canary.ndjson.traces.ndjson",
        "--report", work / "parity.json",
    ], capture_output=True, text=True, check=False)
    for line in parity.stdout.splitlines():
        if line.startswith(("PARITY", "TRANSFER GAP")):
            print(line)
    if not parity.stdout:
        print(parity.stderr)

    base, zero = traces(work / "swift-base.ndjson"), traces(work / "swift-zero_b.ndjson")
    zero_identical = sum(
        base[trace]["raw_output"] == zero[trace]["raw_output"] and base[trace].get("readouts") == zero[trace].get("readouts")
        for trace in base
    )
    adapted = traces(work / "swift-parity.ndjson")

    def accuracy(name: str) -> list[int]:
        rows = [json.loads(line) for line in (work / f"python-{name}.jsonl").read_text().splitlines()]
        return [sum(row["correct"] for row in rows), len(rows)]

    report = {
        "loaded": all(row["variant_id"].endswith(row["variant"]["adapter"]) for row in adapted.values()),
        "held_out_first_slot": {"base": accuracy("base"), "full_adapter": accuracy("full")},
        "parity": json.loads((work / "parity.json").read_text()),
        "zero_b": {"traces": len(base), "identical": zero_identical},
        "training": json.loads((work / "trained" / "training_manifest.json").read_text()),
    }
    (work / "smoke_report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    failures = list(report["parity"]["failures"])
    if not report["loaded"]:
        failures.append("the adapter arm did not record its adapter")
    if zero_identical != len(base):
        failures.append(f"zero-B replay differs from the baseline on {len(base) - zero_identical} traces")
    print("SMOKE " + ("FAIL: " + "; ".join(failures) if failures else "PASS") + f" (report {work / 'smoke_report.json'})")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
