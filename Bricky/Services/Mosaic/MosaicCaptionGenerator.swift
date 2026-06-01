import Foundation

/// Generates an honest, human-readable caption and description for a finished
/// mosaic — entirely on-device, with no LLM or network round-trip.
///
/// Everything it produces is derived from the real mosaic content (grid size,
/// brick count, and the dominant palette colors), so there is never any
/// fabricated detail. The user is free to edit both values afterward.
enum MosaicCaptionGenerator {

    struct Result: Equatable {
        /// Short, title-style caption (e.g. "Bright Blue & Bright Green Mosaic").
        let caption: String
        /// Longer descriptive paragraph.
        let description: String
    }

    /// Build a caption + description from a mosaic's grid and parts list.
    static func generate(
        width: Int,
        height: Int,
        parts: MosaicPartsList,
        brickCount: Int
    ) -> Result {
        let topColors = dominantColors(in: parts)
        return Result(
            caption: makeCaption(width: width, height: height, topColors: topColors),
            description: makeDescription(
                width: width,
                height: height,
                brickCount: brickCount,
                uniqueParts: parts.parts.count,
                topColors: topColors
            )
        )
    }

    // MARK: - Helpers

    /// Colors ranked by total stud quantity (ties broken by name for
    /// determinism).
    private static func dominantColors(in parts: MosaicPartsList) -> [String] {
        var totals: [String: Int] = [:]
        for line in parts.parts {
            totals[line.color, default: 0] += line.qty
        }
        return totals
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .map(\.key)
    }

    private static func makeCaption(width: Int, height: Int, topColors: [String]) -> String {
        guard let primary = topColors.first else {
            return "\(width)×\(height) LEGO Mosaic"
        }
        if topColors.count >= 2 {
            return "\(primary) & \(topColors[1]) Mosaic"
        }
        return "\(primary) Mosaic"
    }

    private static func makeDescription(
        width: Int,
        height: Int,
        brickCount: Int,
        uniqueParts: Int,
        topColors: [String]
    ) -> String {
        let bricks = brickCount.formatted(.number.grouping(.automatic))
        var sentences = [
            "A \(width) × \(height) stud LEGO mosaic built from \(bricks) bricks."
        ]
        if let palette = colorPhrase(topColors) {
            sentences.append("Its palette is led by \(palette).")
        }
        let combos = uniqueParts == 1 ? "1 unique part-and-color combination"
            : "\(uniqueParts) unique part-and-color combinations"
        sentences.append("The full build uses \(combos).")
        return sentences.joined(separator: " ")
    }

    /// Joins up to three color names into a natural-language list.
    private static func colorPhrase(_ colors: [String]) -> String? {
        let top = Array(colors.prefix(3))
        switch top.count {
        case 0: return nil
        case 1: return top[0]
        case 2: return "\(top[0]) and \(top[1])"
        default: return "\(top[0]), \(top[1]), and \(top[2])"
        }
    }
}
