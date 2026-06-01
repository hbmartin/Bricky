import Foundation
import UIKit

/// Instruction generator: brick list + grid → thumbnail image and instructions
/// PDF. On-device port of the backend `app/instructions.py`.
///
/// MVP strategy is row-by-row: a cover page, a parts-list page, then one
/// top-down step per grid row with the active row highlighted. Rendering uses
/// `UIGraphicsImageRenderer` (thumbnail/steps) and `UIGraphicsPDFRenderer`
/// (assembly) — the native equivalents of the backend's Pillow + ReportLab.
enum MosaicInstructionsRenderer {

    private static let gridLine = UIColor(red: 210/255, green: 210/255, blue: 210/255, alpha: 1)
    private static let highlight = UIColor(red: 255/255, green: 64/255, blue: 64/255, alpha: 1)
    private static let background = UIColor(red: 245/255, green: 245/255, blue: 245/255, alpha: 1)

    // US Letter, 72 dpi (matches ReportLab's `letter` and `inch`).
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let inch: CGFloat = 72

    // MARK: - Mosaic Image

    /// Render a top-down mosaic image.
    ///
    /// `upToRow` (inclusive) limits which rows are drawn filled (for step
    /// images); `nil` draws the whole mosaic. `highlightRow` outlines the active
    /// step row in red.
    static func renderMosaic(
        grid: MosaicColorGrid,
        palette: MosaicPalette,
        cellPx: Int = 14,
        upToRow: Int? = nil,
        highlightRow: Int? = nil
    ) -> UIImage {
        let lastRow = upToRow ?? (grid.height - 1)
        let cell = CGFloat(cellPx)
        let size = CGSize(width: CGFloat(grid.width) * cell, height: CGFloat(grid.height) * cell)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            let cg = ctx.cgContext
            background.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            for y in 0..<grid.height {
                for x in 0..<grid.width {
                    let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)
                    if y <= lastRow, let name = grid.cells[y][x], let color = palette.color(named: name) {
                        uiColor(color).setFill()
                        cg.fill(rect)
                    }
                    gridLine.setStroke()
                    cg.stroke(rect.insetBy(dx: 0.5, dy: 0.5), width: 1)
                }
            }

            if let highlightRow {
                let rect = CGRect(
                    x: 1,
                    y: CGFloat(highlightRow) * cell + 1,
                    width: size.width - 2,
                    height: cell - 2
                )
                highlight.setStroke()
                cg.stroke(rect, width: 2)
            }
        }
    }

    /// Render the final mosaic as a small thumbnail (cover image).
    static func renderThumbnail(grid: MosaicColorGrid, palette: MosaicPalette, cellPx: Int = 8) -> UIImage {
        renderMosaic(grid: grid, palette: palette, cellPx: cellPx)
    }

    // MARK: - PDF

    /// Assemble the row-by-row instruction PDF and return its bytes.
    static func buildInstructionsPDF(
        grid: MosaicColorGrid,
        parts: MosaicPartsList,
        palette: MosaicPalette,
        brickCount: Int
    ) -> Data {
        let bounds = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)

        return renderer.pdfData { ctx in
            drawCoverPage(ctx, grid: grid, palette: palette, brickCount: brickCount)
            drawPartsPages(ctx, parts: parts)
            drawStepPages(ctx, grid: grid, palette: palette)
        }
    }

    // MARK: - PDF Pages

    private static func drawCoverPage(
        _ ctx: UIGraphicsPDFRendererContext,
        grid: MosaicColorGrid,
        palette: MosaicPalette,
        brickCount: Int
    ) {
        ctx.beginPage()
        drawCentered("Bricky Mosaic", y: 1.2 * inch, font: .boldSystemFont(ofSize: 24))
        drawCentered("\(grid.width) x \(grid.height) studs", y: 1.6 * inch, font: .systemFont(ofSize: 12))
        drawCentered("\(brickCount) bricks", y: 1.85 * inch, font: .systemFont(ofSize: 12))

        let mosaic = renderMosaic(grid: grid, palette: palette, cellPx: 10)
        let mosaicTop = 2.3 * inch
        drawImageCentered(mosaic, top: mosaicTop, maxHeight: pageSize.height - mosaicTop - inch)
    }

    private static func drawPartsPages(_ ctx: UIGraphicsPDFRendererContext, parts: MosaicPartsList) {
        ctx.beginPage()
        drawString("Parts List", at: CGPoint(x: inch, y: inch), font: .boldSystemFont(ofSize: 18))

        let headerFont = UIFont.boldSystemFont(ofSize: 11)
        var y = 1.4 * inch
        drawString("Part", at: CGPoint(x: inch, y: y), font: headerFont)
        drawString("Color", at: CGPoint(x: inch + 1.2 * inch, y: y), font: headerFont)
        drawString("Qty", at: CGPoint(x: inch + 4.0 * inch, y: y), font: headerFont)

        let rowFont = UIFont.systemFont(ofSize: 11)
        y += 0.25 * inch
        for line in parts.parts {
            if y > pageSize.height - inch {
                ctx.beginPage()
                y = inch
            }
            drawString(line.part, at: CGPoint(x: inch, y: y), font: rowFont)
            drawString(line.color, at: CGPoint(x: inch + 1.2 * inch, y: y), font: rowFont)
            drawString("\(line.qty)", at: CGPoint(x: inch + 4.0 * inch, y: y), font: rowFont)
            y += 0.22 * inch
        }
        drawString(
            "Total: \(parts.totalParts)",
            at: CGPoint(x: inch, y: min(y + 0.1 * inch, pageSize.height - 0.6 * inch)),
            font: headerFont
        )
    }

    private static func drawStepPages(
        _ ctx: UIGraphicsPDFRendererContext,
        grid: MosaicColorGrid,
        palette: MosaicPalette
    ) {
        for row in 0..<grid.height {
            ctx.beginPage()
            drawString(
                "Step \(row + 1) of \(grid.height)",
                at: CGPoint(x: inch, y: inch),
                font: .boldSystemFont(ofSize: 16)
            )
            drawString(
                "Place row \(row + 1).",
                at: CGPoint(x: inch, y: 1.3 * inch),
                font: .systemFont(ofSize: 11)
            )
            let img = renderMosaic(grid: grid, palette: palette, cellPx: 12, upToRow: row, highlightRow: row)
            drawImageCentered(img, top: 1.6 * inch, maxHeight: 7.0 * inch)
        }
    }

    // MARK: - Drawing Primitives (top-left origin, like ReportLab content here)

    private static func drawString(_ text: String, at point: CGPoint, font: UIFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        text.draw(at: point, withAttributes: attrs)
    }

    private static func drawCentered(_ text: String, y: CGFloat, font: UIFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let size = (text as NSString).size(withAttributes: attrs)
        let x = (pageSize.width - size.width) / 2
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }

    /// Draw an image centered horizontally, scaled to fit within
    /// `(pageWidth - 2in) × maxHeight`, with its top edge at `top`.
    private static func drawImageCentered(_ image: UIImage, top: CGFloat, maxHeight: CGFloat) {
        let maxW = pageSize.width - 2 * inch
        let iw = image.size.width
        let ih = image.size.height
        guard iw > 0, ih > 0 else { return }
        let scale = min(maxW / iw, maxHeight / ih)
        let w = iw * scale
        let h = ih * scale
        let x = (pageSize.width - w) / 2
        image.draw(in: CGRect(x: x, y: top, width: w, height: h))
    }

    private static func uiColor(_ color: MosaicPaletteColor) -> UIColor {
        UIColor(
            red: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }
}
