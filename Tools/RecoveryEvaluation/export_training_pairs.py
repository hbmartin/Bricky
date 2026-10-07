#!/usr/bin/env python3
"""Export LoRA training pairs from evidence bundles (ADR 0019). Stdlib only.

One pair per rank trace whose board held the truth: the exact stored board
and the verbatim prompt, with a target that begins with the probe's prefix
and names the truth slot first, so training aims at the decision the probe
reads. Train and test are split by authored model and by physical build,
transitively: sessions sharing an instruction hash, an authored-model id or
a physical-build label always land on the same side.

    python3 export_training_pairs.py BUNDLE [BUNDLE ...] --out DIR

Refused unless --smoke: sessions that are not staged or confirmed, rows from
`replay:` or `synthetic:` devices, sessions without legal-use confirmation,
fewer than 150 labelled sessions, or fewer than two split components on
either side. With --smoke, synthetic bundles are accepted and every pair is
marked smoke; a smoke export never trains anything for use.

Writes train.jsonl, test.jsonl, split_manifest.json (for compare_arms.py
--restrict) and manifest.json (inputs, exclusions by reason, leakage check).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path

PAIR_SCHEMA = "bricky.training_pair.v1"
SPLIT_SCHEMA = "bricky.split_manifest.v1"
EXPORT_SCHEMA = "bricky.training_export.v1"
# RecoveryProbe's rank decision prefix: the target continues it with the
# truth slot, so the first trained token is the probe's first-slot letter.
PROBE_PREFIX = '{ "status": "matched", "ranking": ["'
MINIMUM_LABELLED_SESSIONS = 150
MINIMUM_COMPONENTS_PER_SPLIT = 2
LABEL_KINDS = {"staged", "confirmed"}

# RecoveryInferenceVariant's axes and their baseline values, in the order
# Swift names them in `id` (RecoveryTelemetry.swift).
VARIANT_AXES = (
    ("decode", "legacy", lambda value: f"decode={value}"),
    ("vote", "borda_dedup", lambda value: f"vote={value}"),
    ("unique_slots", False, lambda value: "unique_slots"),
    ("scoring", "generate", lambda value: f"scoring={value}"),
    ("slot_order", "sorted", lambda value: f"slot_order={value}"),
    ("board_layout", "v1", lambda value: f"board={value}"),
    ("labels", "slot_step", lambda value: f"labels={value}"),
    ("prompt_style", "baseline", lambda value: f"prompt={value}"),
    ("image_side", 1024, lambda value: f"image_side={value}"),
    ("check_target", "guide_camera", lambda value: f"check_target={value}"),
    ("adapter", None, lambda value: f"adapter={value}"),
)


def variant_id(variant: dict[str, object] | None) -> str:
    """The id Swift's RecoveryInferenceVariant gives this recorded variant:
    only the axes that differ from the baseline, or `baseline`."""
    variant = variant or {}
    parts = [name(variant[key]) for key, default, name in VARIANT_AXES if key in variant and variant[key] != default]
    return ",".join(parts) if parts else "baseline"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_ndjson(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


@dataclass
class Session:
    session_id: str
    directory: Path
    file: dict[str, object]
    traces: list[dict[str, object]]
    bundle: Path

    @property
    def nodes(self) -> list[str]:
        nodes = [f"sha:{self.file['instruction_sha256']}", f"amid:{self.file['authored_model_id']}"]
        build = self.file.get("physical_build_id")
        if build:
            nodes.append(f"build:{build}")
        return nodes


@dataclass
class Export:
    pairs: list[dict[str, object]] = field(default_factory=list)
    exclusions: dict[str, int] = field(default_factory=dict)
    sessions: list[Session] = field(default_factory=list)

    def exclude(self, reason: str, count: int = 1) -> None:
        self.exclusions[reason] = self.exclusions.get(reason, 0) + count


def session_exclusion(session: Session, *, smoke: bool) -> str | None:
    """Why a session cannot contribute pairs, or None."""
    device = str(session.file.get("device_model", ""))
    if device.startswith("replay:"):
        return "replay_device"
    if device.startswith("synthetic:") and not smoke:
        return "synthetic_device"
    truth = session.file.get("ground_truth") or {}
    kind = truth.get("kind")
    if kind not in LABEL_KINDS:
        return f"label_{kind or 'missing'}"
    if not truth.get("expected_step_id"):
        return "no_expected_step"
    staged = session.file.get("staged")
    if kind == "staged" and not (staged or {}).get("legal_use_confirmed"):
        return "no_legal_use"
    return None


def load_sessions(bundles: list[Path], export: Export, *, smoke: bool) -> None:
    for bundle in bundles:
        manifest = json.loads((bundle / "evidence_bundle.json").read_text())
        for session_id in manifest["session_ids"]:
            directory = bundle / "sessions" / str(session_id)
            session = Session(
                session_id=str(session_id),
                directory=directory,
                file=json.loads((directory / "session.json").read_text()),
                traces=read_ndjson(directory / "traces.ndjson"),
                bundle=bundle,
            )
            reason = session_exclusion(session, smoke=smoke)
            if reason:
                export.exclude(reason)
                continue
            export.sessions.append(session)


def pairs_for(session: Session, export: Export, *, smoke: bool, wanted_variant: str) -> list[dict[str, object]]:
    truth = session.file["ground_truth"]
    expected = truth["expected_step_id"]
    pairs = []
    for trace in session.traces:
        if trace.get("pass") == "check":
            continue
        if variant_id(trace.get("variant")) != wanted_variant:
            export.exclude("other_variant")
            continue
        slots = [slot for slot, step in dict(trace["candidate_step_ids"]).items() if step == expected]
        if not slots:
            export.exclude("truth_not_on_board")
            continue
        board = session.directory / str(trace["board_relative_path"])
        if not board.exists():
            export.exclude("missing_board")
            continue
        slot = sorted(slots)[0]
        pairs.append({
            "schema": PAIR_SCHEMA,
            "trace_id": trace["trace_id"],
            "session_id": session.session_id,
            "image_path": str(board.resolve()),
            "image_sha256": sha256_file(board),
            "image_side": int(dict(trace.get("variant") or {}).get("image_side", 1024)),
            "prompt": trace["prompt"],
            "schema_json": trace["schema_json"],
            "slot_count": len(dict(trace["candidate_step_ids"])),
            "truth_slot": slot,
            "probe_prefix": PROBE_PREFIX,
            "target_text": f'{PROBE_PREFIX}{slot}"]}}',
            "instruction_sha256": session.file["instruction_sha256"],
            "authored_model_id": session.file["authored_model_id"],
            "physical_build_id": session.file.get("physical_build_id"),
            "kind": truth["kind"],
            "pass": trace["pass"],
            "source_model_revision": trace.get("model_revision"),
            "smoke": smoke,
        })
    return pairs


def components(sessions: list[Session]) -> dict[str, list[Session]]:
    """Union-find over each session's identity nodes. Keyed by the
    component's smallest node, so the grouping is order-independent."""
    parent: dict[str, str] = {}

    def find(node: str) -> str:
        parent.setdefault(node, node)
        while parent[node] != node:
            parent[node] = parent[parent[node]]
            node = parent[node]
        return node

    for session in sessions:
        nodes = session.nodes
        for node in nodes[1:]:
            left, right = find(nodes[0]), find(node)
            if left != right:
                parent[max(left, right)] = min(left, right)
    grouped: dict[str, list[Session]] = {}
    for session in sessions:
        grouped.setdefault(find(session.nodes[0]), []).append(session)
    return grouped


def assign(
    grouped: dict[str, list[Session]], *, seed: int, test_fraction: float, holdout: set[str]
) -> tuple[list[str], list[str]]:
    """Components to train and test: forced holdouts first, then in a
    seeded order until the test side holds `test_fraction` of sessions."""
    total = sum(len(members) for members in grouped.values())

    def rank(key: str) -> str:
        return hashlib.sha256(f"{seed}|{key}".encode()).hexdigest()

    forced = sorted(key for key, members in grouped.items() if any(
        str(member.file["instruction_sha256"]) in holdout for member in members
    ))
    test = list(forced)
    held = sum(len(grouped[key]) for key in test)
    for key in sorted((key for key in grouped if key not in forced), key=rank):
        if held >= test_fraction * total:
            break
        test.append(key)
        held += len(grouped[key])
    train = sorted(key for key in grouped if key not in test)
    return train, sorted(test)


def leakage(train: list[dict[str, object]], test: list[dict[str, object]]) -> list[str]:
    """Identity values present on both sides."""
    found = []
    for key in ("instruction_sha256", "authored_model_id", "physical_build_id", "session_id", "image_sha256"):
        shared = {pair[key] for pair in train if pair.get(key)} & {pair[key] for pair in test if pair.get(key)}
        found += [f"{key}={value}" for value in sorted(shared)]
    return found


def run(arguments: argparse.Namespace) -> int:
    export = Export()
    load_sessions(arguments.bundle, export, smoke=arguments.smoke)
    by_session = {
        session.session_id: pairs_for(session, export, smoke=arguments.smoke, wanted_variant=arguments.variant_id)
        for session in export.sessions
    }
    labelled = [session for session in export.sessions if by_session[session.session_id]]
    if not arguments.smoke and len(labelled) < MINIMUM_LABELLED_SESSIONS:
        print(f"refusing: {len(labelled)} labelled sessions with pairs, need {MINIMUM_LABELLED_SESSIONS} (ADR 0019)")
        return 2
    grouped = components(labelled)
    train_keys, test_keys = assign(
        grouped, seed=arguments.seed, test_fraction=arguments.test_fraction, holdout=set(arguments.holdout_sha)
    )
    if not arguments.smoke and min(len(train_keys), len(test_keys)) < MINIMUM_COMPONENTS_PER_SPLIT:
        print(
            f"refusing: {len(train_keys)} train and {len(test_keys)} test components; each side needs "
            f"{MINIMUM_COMPONENTS_PER_SPLIT} (authored models or physical builds) to say anything held out"
        )
        return 2
    if not train_keys or not test_keys:
        print("refusing: one side of the split is empty")
        return 2

    out: Path = arguments.out
    out.mkdir(parents=True, exist_ok=True)
    splits: dict[str, list[dict[str, object]]] = {"train": [], "test": []}
    for name, keys in (("train", train_keys), ("test", test_keys)):
        for key in keys:
            for session in sorted(grouped[key], key=lambda member: member.session_id):
                splits[name] += by_session[session.session_id]
    if arguments.copy_images:
        (out / "images").mkdir(exist_ok=True)
        for pair in splits["train"] + splits["test"]:
            target = out / "images" / f"{pair['image_sha256']}.jpg"
            if not target.exists():
                shutil.copyfile(pair["image_path"], target)
            pair["image_path"] = f"images/{target.name}"
    leaks = leakage(splits["train"], splits["test"])
    for name in ("train", "test"):
        (out / f"{name}.jsonl").write_text("".join(json.dumps(pair, sort_keys=True) + "\n" for pair in splits[name]))
    (out / "split_manifest.json").write_text(json.dumps({
        "schema": SPLIT_SCHEMA,
        "seed": arguments.seed,
        **{
            name: {
                "components": keys,
                "session_ids": sorted({str(pair["session_id"]) for pair in splits[name]}),
                "trace_ids": sorted(str(pair["trace_id"]) for pair in splits[name]),
            }
            for name, keys in (("train", train_keys), ("test", test_keys))
        },
    }, indent=2, sort_keys=True) + "\n")
    (out / "manifest.json").write_text(json.dumps({
        "schema": EXPORT_SCHEMA,
        "smoke": arguments.smoke,
        "variant_id": arguments.variant_id,
        "inputs": [
            {"bundle": str(bundle), "manifest_sha256": sha256_file(bundle / "evidence_bundle.json")}
            for bundle in arguments.bundle
        ],
        "sessions": {
            "labelled": len(labelled),
            "without_physical_build": sum(1 for session in labelled if not session.file.get("physical_build_id")),
        },
        "pairs": {name: len(pairs) for name, pairs in splits.items()},
        "exclusions": dict(sorted(export.exclusions.items())),
        "leakage": {"checked": ["instruction_sha256", "authored_model_id", "physical_build_id", "session_id",
                                "image_sha256"], "violations": leaks},
    }, indent=2, sort_keys=True) + "\n")
    print(
        f"{len(splits['train'])} train and {len(splits['test'])} test pairs from {len(labelled)} sessions "
        f"({len(train_keys)}/{len(test_keys)} components); exclusions {dict(sorted(export.exclusions.items()))}"
    )
    if leaks:
        print(f"refusing: identities on both sides of the split: {', '.join(leaks)}")
        return 2
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("bundle", type=Path, nargs="+", help="unzipped evidence bundle directories")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--test-fraction", type=float, default=0.25)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--variant-id", default="baseline", help="export only traces recorded under this variant")
    parser.add_argument("--holdout-sha", action="append", default=[], help="force an instruction hash into test")
    parser.add_argument("--copy-images", action="store_true", help="copy boards into <out>/images by content hash")
    parser.add_argument("--smoke", action="store_true", help="accept synthetic bundles; mark every pair smoke")
    return run(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
