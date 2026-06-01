"""Tests for parts aggregation."""
from __future__ import annotations

from app.contracts import Brick
from app.parts import aggregate, parts_to_dict

from .conftest import palette


def _bricks():
    return [
        Brick(x=0, y=0, length=2, color="Bright Red"),
        Brick(x=2, y=0, length=2, color="Bright Red"),
        Brick(x=0, y=1, length=1, color="Black"),
    ]


def test_total_equals_brick_count():
    bricks = _bricks()
    parts = aggregate(bricks, palette())
    assert parts.total_parts == len(bricks)


def test_aggregation_by_part_and_color():
    parts = aggregate(_bricks(), palette())
    by_key = {(p.part, p.color): p.qty for p in parts.parts}
    assert by_key[("3023", "Bright Red")] == 2  # two 1x2 red plates
    assert by_key[("3024", "Black")] == 1


def test_color_ids_attached():
    parts = aggregate(_bricks(), palette())
    red = next(p for p in parts.parts if p.color == "Bright Red")
    assert red.ldraw_color == 4
    assert red.bricklink_color == 5
    assert red.rebrickable_color == 4


def test_deterministic_ordering():
    parts = aggregate(_bricks(), palette())
    keys = [(p.part, p.color) for p in parts.parts]
    assert keys == sorted(keys)


def test_parts_to_dict_schema():
    parts = aggregate(_bricks(), palette())
    d = parts_to_dict(parts)
    assert d["palette_id"] == "mvp-v1"
    assert d["total_parts"] == len(_bricks())
    assert set(d["parts"][0].keys()) == {
        "part",
        "color",
        "qty",
        "ldraw_color",
        "bricklink_color",
        "rebrickable_color",
    }


def test_empty_brick_list():
    parts = aggregate([], palette())
    assert parts.total_parts == 0
    assert parts.parts == []
