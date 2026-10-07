#!/usr/bin/env python3
"""Blinded preference test for repair wording (ADR 0017).

`bricky-harness wording-sheet` writes two CSV files from device
`wording.ndjson` pairs:

- the sheet (`pair_id, action, option_a, option_b, choice`), where each
  pair's template and model sentence are placed A or B at random;
- the key (`pair_id, model_option, os_build, device_model`), kept from
  the rater.

The rater fills `choice` with A, B, or = for no preference. This script
unblinds and runs an exact one-sided sign test: does the model sentence
win more often than chance? Ties carry no information and are dropped.

    python3 score_wording_ab.py --sheet sheet.csv --key key.csv

The language layer's default flips only on MODEL PREFERRED from device
pairs (a Mac is not the phone's model tier), per OS build.
"""

from __future__ import annotations

import argparse
import csv
import math
from dataclasses import dataclass
from pathlib import Path

ALPHA = 0.05


@dataclass
class Tally:
    wins: int = 0
    losses: int = 0
    ties: int = 0
    unrated: int = 0

    @property
    def decided(self) -> int:
        return self.wins + self.losses

    @property
    def p_value(self) -> float:
        """One-sided exact sign test: P(at least `wins` model wins among the
        decided pairs | no preference)."""
        n = self.decided
        if n == 0:
            return 1.0
        return sum(math.comb(n, k) for k in range(self.wins, n + 1)) / 2 ** n

    @property
    def decision(self) -> str:
        if self.decided == 0:
            return "UNMEASURED (no decided pairs)"
        if self.wins > self.losses and self.p_value < ALPHA:
            return "MODEL PREFERRED"
        if self.losses > self.wins and Tally(wins=self.losses, losses=self.wins).p_value < ALPHA:
            return "TEMPLATE PREFERRED"
        return "NO PREFERENCE"


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def score(sheet: list[dict[str, str]], key: list[dict[str, str]]) -> Tally:
    model_option = {row["pair_id"]: row["model_option"].strip().upper() for row in key}
    tally = Tally()
    for row in sheet:
        pair = row["pair_id"]
        if pair not in model_option:
            raise SystemExit(f"pair {pair} is not in the key")
        if model_option[pair] not in {"A", "B"}:
            raise SystemExit(f"pair {pair} has an invalid model_option {model_option[pair]!r}")
        choice = (row.get("choice") or "").strip().upper()
        if not choice:
            tally.unrated += 1
        elif choice == "=":
            tally.ties += 1
        elif choice not in {"A", "B"}:
            raise SystemExit(f"pair {pair} has an invalid choice {choice!r}; use A, B or =")
        elif choice == model_option[pair]:
            tally.wins += 1
        else:
            tally.losses += 1
    return tally


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sheet", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    arguments = parser.parse_args(argv)
    tally = score(read_rows(arguments.sheet), read_rows(arguments.key))
    print(
        f"WORDING_PREFERENCE model {tally.wins} / template {tally.losses} "
        f"(ties {tally.ties}, unrated {tally.unrated}); one-sided sign test p={tally.p_value:.4f}"
    )
    print(f"VERDICT {tally.decision}")
    if tally.unrated:
        print("note: unrated pairs are excluded; rate every pair before deciding")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
