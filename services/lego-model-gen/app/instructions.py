"""Instruction generator: brick list + grid -> thumbnail PNG and instructions PDF.

MVP strategy is row-by-row (INSTRUCTIONS_GENERATOR.md sec.2.1): a cover page, a parts
list page, then one top-down step per grid row with the active row highlighted.
Rendering uses Pillow; PDF assembly uses ReportLab.
"""
from __future__ import annotations

import io
from typing import List, Optional, Tuple

from PIL import Image, ImageDraw
from reportlab.lib.pagesizes import letter
from reportlab.lib.units import inch
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas

from .contracts import ColorGrid, PartsList
from .palette import Palette

_GRID_LINE = (210, 210, 210)
_HIGHLIGHT = (255, 64, 64)
_BACKGROUND = (245, 245, 245)


def _cell_rgb(grid: ColorGrid, palette: Palette, x: int, y: int) -> Optional[Tuple[int, int, int]]:
    name = grid.cells[y][x]
    if name is None:
        return None
    return palette.by_name(name).rgb


def render_mosaic(
    grid: ColorGrid,
    palette: Palette,
    cell_px: int = 14,
    up_to_row: Optional[int] = None,
    highlight_row: Optional[int] = None,
) -> Image.Image:
    """Render a top-down mosaic image.

    `up_to_row` (inclusive) limits which rows are drawn filled (for step images);
    None draws the whole mosaic. `highlight_row` outlines the active step row.
    """
    last_row = grid.height - 1 if up_to_row is None else up_to_row
    img = Image.new("RGB", (grid.width * cell_px, grid.height * cell_px), _BACKGROUND)
    draw = ImageDraw.Draw(img)

    for y in range(grid.height):
        for x in range(grid.width):
            x0, y0 = x * cell_px, y * cell_px
            x1, y1 = x0 + cell_px, y0 + cell_px
            rgb = _cell_rgb(grid, palette, x, y)
            if y <= last_row and rgb is not None:
                draw.rectangle([x0, y0, x1, y1], fill=rgb)
            draw.rectangle([x0, y0, x1, y1], outline=_GRID_LINE)

    if highlight_row is not None:
        y0 = highlight_row * cell_px
        y1 = y0 + cell_px
        draw.rectangle(
            [0, y0, grid.width * cell_px - 1, y1 - 1], outline=_HIGHLIGHT, width=2
        )
    return img


def _png_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def render_thumbnail(grid: ColorGrid, palette: Palette, cell_px: int = 8) -> bytes:
    """Render the final mosaic as a PNG thumbnail (cover image)."""
    return _png_bytes(render_mosaic(grid, palette, cell_px=cell_px))


def _draw_image_centered(c: canvas.Canvas, img: Image.Image, top: float, max_h: float) -> float:
    """Draw a PIL image centered horizontally; return the y of its bottom edge."""
    page_w, _ = letter
    iw, ih = img.size
    max_w = page_w - 2 * inch
    scale = min(max_w / iw, max_h / ih)
    w, h = iw * scale, ih * scale
    x = (page_w - w) / 2
    y = top - h
    c.drawImage(ImageReader(io.BytesIO(_png_bytes(img))), x, y, width=w, height=h)
    return y


def build_instructions_pdf(
    grid: ColorGrid, parts: PartsList, palette: Palette, brick_count: int
) -> bytes:
    """Assemble the row-by-row instruction PDF and return its bytes."""
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=letter)
    page_w, page_h = letter

    # --- Cover page ---
    c.setFont("Helvetica-Bold", 24)
    c.drawCentredString(page_w / 2, page_h - 1.2 * inch, "Bricky Mosaic")
    c.setFont("Helvetica", 12)
    c.drawCentredString(
        page_w / 2, page_h - 1.6 * inch, f"{grid.width} x {grid.height} studs"
    )
    c.drawCentredString(page_w / 2, page_h - 1.85 * inch, f"{brick_count} bricks")
    _draw_image_centered(
        c, render_mosaic(grid, palette, cell_px=10), page_h - 2.2 * inch, 6.0 * inch
    )
    c.showPage()

    # --- Parts list page ---
    c.setFont("Helvetica-Bold", 18)
    c.drawString(inch, page_h - inch, "Parts List")
    c.setFont("Helvetica-Bold", 11)
    y = page_h - 1.4 * inch
    c.drawString(inch, y, "Part")
    c.drawString(inch + 1.2 * inch, y, "Color")
    c.drawString(inch + 4.0 * inch, y, "Qty")
    c.setFont("Helvetica", 11)
    y -= 0.25 * inch
    for line in parts.parts:
        if y < inch:
            c.showPage()
            c.setFont("Helvetica", 11)
            y = page_h - inch
        c.drawString(inch, y, line.part)
        c.drawString(inch + 1.2 * inch, y, line.color)
        c.drawString(inch + 4.0 * inch, y, str(line.qty))
        y -= 0.22 * inch
    c.setFont("Helvetica-Bold", 11)
    c.drawString(inch, max(y - 0.1 * inch, 0.6 * inch), f"Total: {parts.total_parts}")
    c.showPage()

    # --- Step pages (row-by-row) ---
    for row in range(grid.height):
        c.setFont("Helvetica-Bold", 16)
        c.drawString(inch, page_h - inch, f"Step {row + 1} of {grid.height}")
        c.setFont("Helvetica", 11)
        c.drawString(inch, page_h - 1.3 * inch, f"Place row {row + 1}.")
        img = render_mosaic(grid, palette, cell_px=12, up_to_row=row, highlight_row=row)
        _draw_image_centered(c, img, page_h - 1.6 * inch, 7.0 * inch)
        c.showPage()

    c.save()
    return buf.getvalue()


__all__ = ["render_mosaic", "render_thumbnail", "build_instructions_pdf"]
