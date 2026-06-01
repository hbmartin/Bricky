import Foundation

/// LDraw export: ordered brick list → a single deterministic `.ldr` text.
/// Faithful port of the backend `app/ldraw.py`.
///
/// Coordinates are LDU (1 stud = 20). The mosaic is a vertical wall facing the
/// builder: X = column·20, Y = row·20, Z = 0 for the single MVP layer. Bricks
/// are written in a stable order (layer, row, column) so exports are
/// reproducible and match step order.
enum MosaicLDRExporter {

    private static let identity = "1 0 0 0 1 0 0 0 1"

    private static let header = [
        "0 Mosaic Model",
        "0 Name: model.ldr",
        "0 Author: Bricky Model Generation System",
        "0 !LDRAW_ORG Unofficial_Model",
        "0 BFC CERTIFY CCW",
    ]

    /// Deterministic order: layer (Z=0 for MVP), then row (Y), then column (X).
    static func sorted(_ bricks: [MosaicBrick]) -> [MosaicBrick] {
        bricks.sorted { lhs, rhs in
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.x < rhs.x
        }
    }

    /// Render the brick list as the text of a single `.ldr` file.
    static func export(_ bricks: [MosaicBrick], palette: MosaicPalette) -> String {
        var lines = header
        for brick in sorted(bricks) {
            let colorId = palette.color(named: brick.color)?.ldraw ?? 0
            let x = brick.x * MosaicContract.lduPerStud
            let y = brick.y * MosaicContract.lduPerStud
            let z = 0
            lines.append("1 \(colorId) \(x) \(y) \(z) \(identity) \(brick.part).dat")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
