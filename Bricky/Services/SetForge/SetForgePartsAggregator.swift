import Foundation

/// Aggregates a Set Forge brick list into a bill of materials: one line per
/// unique (length, colour) brick with a quantity, plus convenience totals.
enum SetForgePartsAggregator {

    /// A single line in the parts list.
    struct Part: Equatable, Codable, Hashable, Identifiable {
        var length: Int
        var color: LegoColor
        var quantity: Int

        var id: String { "\(length)-\(color.rawValue)" }
        var part: String { SetForgeContract.part(forLength: length) }
        var name: String { SetForgeContract.name(forLength: length) }
        var displayName: String { "\(quantity)× \(color.rawValue) \(name)" }
    }

    static func aggregate(_ bricks: [PlacedBrick]) -> [Part] {
        var counts: [String: Part] = [:]
        for brick in bricks {
            let key = "\(brick.length)-\(brick.color.rawValue)"
            if var existing = counts[key] {
                existing.quantity += 1
                counts[key] = existing
            } else {
                counts[key] = Part(length: brick.length, color: brick.color, quantity: 1)
            }
        }
        // Deterministic ordering: most-used first, then longer bricks, then colour.
        return counts.values.sorted { a, b in
            if a.quantity != b.quantity { return a.quantity > b.quantity }
            if a.length != b.length { return a.length > b.length }
            return a.color.rawValue < b.color.rawValue
        }
    }

    /// Convert the BOM to the app's shared `RequiredPiece` model so a forged set
    /// can flow through the existing inventory-match and build-instructions UI.
    static func requiredPieces(_ parts: [Part]) -> [RequiredPiece] {
        parts.map { part in
            RequiredPiece(
                category: .brick,
                dimensions: PieceDimensions(studsWide: part.length, studsLong: 1, heightUnits: 3),
                colorPreference: part.color,
                quantity: part.quantity,
                flexible: false
            )
        }
    }
}
