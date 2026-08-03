#!/usr/bin/env python3
"""Create the same bounded one-image recovery board used by device inference."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


def fit(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    copy = image.copy()
    copy.thumbnail(size)
    return copy


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("physical", type=Path)
    parser.add_argument("candidates", nargs="+", type=Path)
    parser.add_argument("--step-labels", nargs="+")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if len(args.candidates) > 8:
        raise SystemExit("at most eight candidates")
    if args.step_labels is not None and len(args.step_labels) != len(args.candidates):
        raise SystemExit("--step-labels must contain one value per candidate")
    board = Image.new("RGB", (1024, 1024), (15, 15, 15))
    physical = ImageOps.fit(
        Image.open(args.physical).convert("RGB"),
        (992, 420),
        method=Image.Resampling.LANCZOS,
    )
    board.paste(physical, (16, 16))
    draw = ImageDraw.Draw(board)
    for index, path in enumerate(args.candidates):
        column, row = index % 4, index // 4
        tile_width, tile_height, gap = 239, 266, 12
        x, y = 16 + column * (tile_width + gap), 452 + row * (tile_height + gap)
        draw.rounded_rectangle(
            (x, y, x + tile_width, y + tile_height),
            radius=14,
            fill=(36, 36, 36),
        )
        image = fit(Image.open(path).convert("RGB"), (tile_width - 16, tile_height - 60))
        board.paste(
            image,
            (
                x + (tile_width - image.width) // 2,
                y + 30 + (tile_height - 60 - image.height) // 2,
            ),
        )
        slot = chr(65 + index)
        step = args.step_labels[index] if args.step_labels is not None else str(index + 1)
        try:
            font = ImageFont.truetype("DejaVuSansMono-Bold.ttf", 19)
        except OSError:
            font = ImageFont.load_default()
        draw.text((x + 10, y + 7), f"{slot} · Step {step}", fill="white", font=font)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    board.save(args.out, quality=90)


if __name__ == "__main__":
    main()
