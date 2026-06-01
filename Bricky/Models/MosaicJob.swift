import Foundation

/// Value types for the on-device LEGO mosaic engine
/// (`Bricky/Services/Mosaic/`).
///
/// Mosaic generation runs entirely on-device — there is no backend. These types
/// describe the snapped grid size and the aggregated parts inventory surfaced in
/// the UI. JSON `CodingKeys` keep the `snake_case` shape used by the golden
/// fixtures the engine is validated against.

/// Resolved (snapped) grid size for a generated mosaic.
struct MosaicJobGrid: Codable, Sendable, Equatable {
    let width: Int
    let height: Int
}

/// One aggregated part line in a mosaic's bill of materials.
struct MosaicPartLine: Codable, Sendable, Equatable, Identifiable {
    let part: String
    let color: String
    let qty: Int
    let ldrawColor: Int
    let bricklinkColor: Int
    let rebrickableColor: Int

    var id: String { "\(part)-\(color)" }

    enum CodingKeys: String, CodingKey {
        case part
        case color
        case qty
        case ldrawColor = "ldraw_color"
        case bricklinkColor = "bricklink_color"
        case rebrickableColor = "rebrickable_color"
    }
}

/// The aggregated parts list for a generated mosaic.
struct MosaicPartsList: Codable, Sendable, Equatable {
    let paletteId: String
    let parts: [MosaicPartLine]
    let totalParts: Int

    enum CodingKeys: String, CodingKey {
        case paletteId = "palette_id"
        case parts
        case totalParts = "total_parts"
    }
}
