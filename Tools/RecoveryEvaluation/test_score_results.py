from __future__ import annotations

import unittest

from score_results import validate_release_corpus, validate_rows


def benchmark_row(*, certainty: str = "high", include_top: bool = True) -> dict[str, object]:
    row: dict[str, object] = {
        "schema_version": 1,
        "fixture_id": "fixture",
        "instruction_sha256": "0" * 64,
        "pyldraw3_version": "1.5.0",
        "part_pack_version": "2026-07",
        "expected_step_id": "main.ldr#2",
        "candidate_slots": {"A": "main.ldr#2", "B": "main.ldr#1"},
        "board_relative_paths": ["boards/fixture.jpg"],
        "camera_metadata": [{"fx": 1_200.0, "fy": 1_200.0}],
        "expected_step_index": 2,
        "ranked_step_ids": [] if certainty == "insufficient" else ["main.ldr#2"],
        "certainty": certainty,
        "device_model": "iPhone",
        "operating_system": "iOS",
        "latency_ms": 12_000,
        "memory_peak_bytes": 4_800_000_000,
    }
    if include_top:
        row["top_step_index"] = None if certainty == "insufficient" else 2
    return row


class RowValidationTests(unittest.TestCase):
    def test_insufficient_row_may_omit_top_step_index(self) -> None:
        validate_rows([benchmark_row(certainty="insufficient", include_top=False)])

    def test_sufficient_row_requires_top_step_index(self) -> None:
        with self.assertRaisesRegex(SystemExit, "requires top_step_index"):
            validate_rows([benchmark_row(include_top=False)])

    def test_boolean_is_not_accepted_as_an_integer_index(self) -> None:
        row = benchmark_row()
        row["top_step_index"] = True
        with self.assertRaisesRegex(SystemExit, "integer >= -1"):
            validate_rows([row])


class ReleaseCorpusValidationTests(unittest.TestCase):
    @staticmethod
    def release_rows(fixture_id: str | None = None) -> list[dict[str, object]]:
        rows: list[dict[str, object]] = []
        for index in range(150):
            row = benchmark_row()
            row.update(
                fixture_id=fixture_id or f"fixture-{index}",
                physical_case=True,
                authored_model_id=f"model-{index % 10}",
                legal_use_confirmed=True,
                lighting_condition="daylight" if index % 2 else "indoor",
                capture_angle="left" if index % 2 else "right",
                occlusion_condition="none" if index % 2 else "partial",
            )
            rows.append(row)
        return rows

    def test_complete_physical_corpus_passes_preflight(self) -> None:
        rows = self.release_rows()
        validate_rows(rows)
        validate_release_corpus(rows)

    def test_duplicated_fixture_ids_fail_preflight(self) -> None:
        with self.assertRaisesRegex(SystemExit, "distinct fixture IDs"):
            validate_release_corpus(self.release_rows(fixture_id="fixture-repeated"))

    def test_release_row_requires_explicit_provenance(self) -> None:
        rows = [benchmark_row() for _ in range(150)]
        with self.assertRaisesRegex(SystemExit, "missing fields"):
            validate_release_corpus(rows)


if __name__ == "__main__":
    unittest.main()
