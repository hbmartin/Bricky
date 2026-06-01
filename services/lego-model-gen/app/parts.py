"""Parts & inventory: brick list -> parts.json (PARTS_INVENTORY.md / DATA_CONTRACTS sec.5).

Aggregates bricks by (part, color), attaches cross-system color IDs from the palette,
and reports the total. `total_parts == sum(qty) == len(bricks)`.
"""
from __future__ import annotations

from typing import Dict, List, Tuple

from .contracts import Brick, PartLine, PartsList
from .palette import Palette


def aggregate(bricks: List[Brick], palette: Palette) -> PartsList:
    """Count bricks by (part, color) and resolve color IDs from the palette."""
    counts: Dict[Tuple[str, str], int] = {}
    for brick in bricks:
        key = (brick.part, brick.color)
        counts[key] = counts.get(key, 0) + 1

    lines: List[PartLine] = []
    # Deterministic ordering: by part id, then color name.
    for (part, color) in sorted(counts.keys()):
        c = palette.by_name(color)
        lines.append(
            PartLine(
                part=part,
                color=color,
                qty=counts[(part, color)],
                ldraw_color=c.ldraw,
                bricklink_color=c.bricklink,
                rebrickable_color=c.rebrickable,
            )
        )

    total = sum(line.qty for line in lines)
    return PartsList(palette_id=palette.palette_id, parts=lines, total_parts=total)


def parts_to_dict(parts: PartsList) -> dict:
    """Serialize a PartsList to the parts.json schema (DATA_CONTRACTS.md sec.5)."""
    return {
        "palette_id": parts.palette_id,
        "parts": [
            {
                "part": p.part,
                "color": p.color,
                "qty": p.qty,
                "ldraw_color": p.ldraw_color,
                "bricklink_color": p.bricklink_color,
                "rebrickable_color": p.rebrickable_color,
            }
            for p in parts.parts
        ],
        "total_parts": parts.total_parts,
    }
