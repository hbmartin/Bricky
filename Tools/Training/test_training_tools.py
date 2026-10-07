"""Local tests for the training tools' pure logic (no MLX). Not run in CI:
    uv run python -m unittest test_training_tools.py
"""

from __future__ import annotations

import math
import unittest

from convert_adapter import check_name, parse_name, plan, swift_config
from parity_check import agrees, compare, verdict

KEYS = ["self_attn.q_proj", "self_attn.v_proj"]


def template(total: int = 4, rank: int = 8) -> dict[str, object]:
    tensors = {}
    for layer in range(total):
        for key in KEYS:
            tensors[f"language_model.model.layers.{layer}.{key}.lora_a"] = [32, rank]
            tensors[f"language_model.model.layers.{layer}.{key}.lora_b"] = [rank, 64]
    return {"layer_prefix": "language_model.model.layers.", "dtype": "BF16", "total_layers": total,
            "num_layers": total, "keys": KEYS + ["mlp.up_proj"], "tensors": tensors}


def adapter(layers, rank: int = 4, transpose: bool = False) -> dict[str, list[int]]:
    shapes = {}
    for layer in layers:
        for key in KEYS:
            a, b = [32, rank], [rank, 64]
            if transpose:
                a, b = a[::-1], b[::-1]
            shapes[f"language_model.model.layers.{layer}.{key}.lora_a"] = a
            shapes[f"language_model.model.layers.{layer}.{key}.lora_b"] = b
    return shapes


CONFIG = {"fine_tune_type": "lora", "num_layers": 16,
          "lora_parameters": {"rank": 4, "scale": 2.0, "dropout": 0.0,
                              "keys": ["language_model.model.layers.0.self_attn.q_proj"]}}


class ConvertTests(unittest.TestCase):
    def test_a_trained_adapter_becomes_a_swift_config(self) -> None:
        result = plan(CONFIG, adapter(range(4)), template())
        self.assertEqual((result.num_layers, result.layers, result.keys), (4, [0, 1, 2, 3], KEYS))
        self.assertEqual(result.transpose, set())
        config = swift_config(result, name="first-slot.v1", base_revision="rev", smoke=False, scale_multiplier=1.0)
        # The scale is the effective multiplier mlx-vlm computed (alpha / rank),
        # always written: the Swift default would be 10 or 20.
        self.assertEqual(config["lora_parameters"], {"rank": 4, "scale": 2.0, "keys": KEYS})
        self.assertEqual(config["num_layers"], 4)
        self.assertEqual(config["bricky"], {"name": "first-slot.v1", "base_model_revision": "rev", "smoke": False})

    def test_a_suffix_of_layers_is_accepted_and_a_gap_is_not(self) -> None:
        self.assertEqual(plan(CONFIG, adapter([2, 3]), template()).layers, [2, 3])
        with self.assertRaisesRegex(ValueError, "last 2 of 4"):
            plan(CONFIG, adapter([0, 1]), template())

    def test_transposed_tensors_are_flipped(self) -> None:
        self.assertEqual(len(plan(CONFIG, adapter(range(4), transpose=True), template()).transpose), 16)

    def test_wrong_shapes_and_names_are_refused(self) -> None:
        with self.assertRaisesRegex(ValueError, "the Swift model needs"):
            plan(CONFIG, adapter(range(4), rank=3), template())
        legacy = {name.replace(".lora_a", ".A").replace(".lora_b", ".B"): shape for name, shape in adapter(range(4)).items()}
        with self.assertRaisesRegex(ValueError, "legacy A/B"):
            plan(CONFIG, legacy, template())
        vision = dict(adapter(range(4)), **{"vision_tower.blocks.0.attn.qkv.lora_a": [32, 4]})
        with self.assertRaisesRegex(ValueError, "not a language-model decoder layer"):
            plan(CONFIG, vision, template())
        missing = adapter(range(4))
        del missing["language_model.model.layers.3.self_attn.v_proj.lora_b"]
        with self.assertRaisesRegex(ValueError, "lacks lora_a or lora_b"):
            plan(CONFIG, missing, template())
        with self.assertRaisesRegex(ValueError, "legacy mlx-vlm adapter"):
            plan({"rank": 8, "alpha": 16}, adapter(range(4)), template())

    def test_names_mark_smoke_adapters(self) -> None:
        check_name("smoke-1", smoke=True)
        check_name("first-slot.v1", smoke=False)
        for name, smoke in (("first-slot", True), ("smoke-1", False), ("Bad Name", False)):
            with self.assertRaises(ValueError):
                check_name(name, smoke=smoke)

    def test_parse_name(self) -> None:
        self.assertEqual(parse_name("language_model.model.layers.12.mlp.down_proj.lora_b"), (12, "mlp.down_proj", "lora_b"))


def python_row(trace: str, logprobs: dict[str, float]) -> dict[str, object]:
    return {"trace_id": trace, "truth_slot": "A", "slot_logprobs": logprobs, "prompt_tokens": 1096, "image_tokens": 1024}


def swift_row(trace: str, logprobs: dict[str, float]) -> dict[str, object]:
    total = sum(math.exp(value) for value in logprobs.values())
    return {
        "trace_id": trace,
        "inference": {"decode": {"prompt_tokens": 1096, "image_tokens": 1024}},
        "readouts": [{"candidates": [{"text": "ins", "probability": 0.9}]}, {"candidates": [
            {"text": letter, "probability": math.exp(value) / total} for letter, value in logprobs.items()
        ]}],
    }


class ParityTests(unittest.TestCase):
    base = {"A": -1.0, "B": -1.5, "C": -2.0}

    def shifted(self, amount: float) -> dict[str, float]:
        # The adapter raises the truth slot by `amount` nats.
        return dict(self.base, A=self.base["A"] + amount)

    def rows(self, swift_gain: float, *, offset: float = 0.0):
        # Each board moves by its own amount, as real boards do.
        shifts = [0.5, 1.0, 1.5]
        python_base = [python_row(f"t{i}", self.base) for i in range(3)]
        python_adapter = [python_row(f"t{i}", self.shifted(shifts[i])) for i in range(3)]
        # Swift differs from Python by a constant per letter (different
        # MLX builds), which must not matter.
        swift_base_logprobs = {letter: value + offset * index for index, (letter, value) in enumerate(self.base.items())}
        swift_base = [swift_row(f"t{i}", swift_base_logprobs) for i in range(3)]
        swift_adapter = [
            swift_row(f"t{i}", dict(swift_base_logprobs, A=swift_base_logprobs["A"] + shifts[i] * swift_gain))
            for i in range(3)
        ]
        return python_base, python_adapter, swift_base, swift_adapter

    def test_matching_effects_agree_despite_a_base_offset(self) -> None:
        result = compare(*self.rows(1.0, offset=0.2))
        self.assertAlmostEqual(result["slope"], 1.0, places=6)
        self.assertGreater(result["base_log_odds_error_max"], 0.1)
        self.assertTrue(agrees(result))

    def test_a_doubled_scale_canary_must_stand_out(self) -> None:
        matched, doubled = compare(*self.rows(1.0)), compare(*self.rows(2.0))
        self.assertAlmostEqual(doubled["slope"], 2.0, places=6)
        self.assertEqual(verdict(matched, doubled), ([], []))
        # A canary no stronger than the adapter means the check is blind
        # to a scale mix-up.
        failures, _ = verdict(matched, matched)
        self.assertEqual(len(failures), 1)
        self.assertIn("canary", failures[0])
        failures, _ = verdict(matched, None)
        self.assertIn("no canary", failures[0])

    def test_a_transfer_gap_is_reported_not_failed(self) -> None:
        # Swift applies the same adapter (same pattern, doubling shows) but
        # its model is less sensitive: a note for ADR 0019, not a failure.
        weaker, weaker_doubled = compare(*self.rows(0.73)), compare(*self.rows(1.46))
        failures, notes = verdict(weaker, weaker_doubled)
        self.assertEqual(failures, [])
        self.assertEqual(len(notes), 1)
        self.assertIn("TRANSFER GAP", notes[0])

    def test_token_count_mismatch_fails(self) -> None:
        python_base, python_adapter, swift_base, swift_adapter = self.rows(1.0)
        python_base[0]["image_tokens"] = 256
        result = compare(python_base, python_adapter, swift_base, swift_adapter)
        self.assertEqual(len(result["token_mismatches"]), 1)
        self.assertFalse(agrees(result))

    def test_a_scattered_cloud_fails_even_with_a_unit_slope(self) -> None:
        # A saturated adapter: Swift's changes are as large as Python's but
        # land in no particular pattern, so the slope alone would pass.
        python_shifts = [(-10.0, -12.0), (-11.0, -9.0), (-12.0, -10.0), (-9.0, -11.0)]
        python_base, python_adapter, swift_base, swift_adapter = [], [], [], []
        for index, (python_shift, swift_shift) in enumerate(python_shifts):
            trace = f"t{index}"
            python_base.append(python_row(trace, self.base))
            python_adapter.append(python_row(trace, dict(self.base, A=self.base["A"] - python_shift)))
            swift_base.append(swift_row(trace, self.base))
            swift_adapter.append(swift_row(trace, dict(self.base, A=self.base["A"] - swift_shift)))
        result = compare(python_base, python_adapter, swift_base, swift_adapter)
        self.assertAlmostEqual(result["slope"], 1.0, delta=0.1)
        self.assertLess(result["correlation"], 0.9)
        self.assertFalse(agrees(result))

    def test_an_adapter_that_changes_nothing_has_no_slope(self) -> None:
        python_base, _, swift_base, _ = self.rows(1.0)
        result = compare(python_base, python_base, swift_base, swift_base)
        self.assertIsNone(result["slope"])
        self.assertFalse(agrees(result))


if __name__ == "__main__":
    unittest.main()
