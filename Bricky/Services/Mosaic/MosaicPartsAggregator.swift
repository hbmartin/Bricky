import Foundation

/// Parts & inventory: brick list → `MosaicPartsList`. Faithful port of the
/// backend `app/parts.py`.
///
/// Aggregates bricks by `(part, color)`, attaches cross-system color IDs from
/// the palette, and reports the total. Invariant:
/// `totalParts == sum(qty) == bricks.count`.
enum MosaicPartsAggregator {

    static func aggregate(_ bricks: [MosaicBrick], palette: MosaicPalette) -> MosaicPartsList {
        var counts: [Key: Int] = [:]
        for brick in bricks {
            counts[Key(part: brick.part, color: brick.color), default: 0] += 1
        }

        // Deterministic ordering: by part id, then color name.
        let lines: [MosaicPartLine] = counts.keys
            .sorted { lhs, rhs in
                if lhs.part != rhs.part { return lhs.part < rhs.part }
                return lhs.color < rhs.color
            }
            .map { key in
                let color = palette.color(named: key.color)
                return MosaicPartLine(
                    part: key.part,
                    color: key.color,
                    qty: counts[key] ?? 0,
                    ldrawColor: color?.ldraw ?? 0,
                    bricklinkColor: color?.bricklink ?? 0,
                    rebrickableColor: color?.rebrickable ?? 0
                )
            }

        let total = lines.reduce(0) { $0 + $1.qty }
        return MosaicPartsList(paletteId: palette.paletteId, parts: lines, totalParts: total)
    }

    private struct Key: Hashable {
        let part: String
        let color: String
    }
}
