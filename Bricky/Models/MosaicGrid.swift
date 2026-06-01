import Foundation

/// A quantized LEGO color grid — the deterministic output of the vision
/// pipeline's first stage and the **sole input** to brick packing.
///
/// Conforms to the Color Grid Contract in
/// `docs/LEGO Model Generation System/DATA_CONTRACTS.md` §3:
/// - `cells` is **row-major**: `cells.count == height`,
///   `cells[r].count == width`.
/// - Each entry is a `LegoColor` or `nil` (a background / omitted stud).
///
/// Studs are addressed `(x, y)` with the origin at the **top-left**, `x`
/// increasing right and `y` increasing down — matching image row/column
/// order and the Brick List Contract (§4).
struct MosaicGrid: Codable, Equatable {

    /// Width in studs (columns).
    let width: Int

    /// Height in studs (rows).
    let height: Int

    /// Identifier of the palette the cells were quantized against
    /// (e.g. `"mvp-v1"`). Lets downstream stages resolve cross-system
    /// color IDs deterministically.
    let paletteId: String

    /// Row-major cells. `cells[y][x]` is the color of the stud at
    /// `(x, y)`, or `nil` for an empty/background stud.
    let cells: [[LegoColor?]]

    init(width: Int, height: Int, paletteId: String, cells: [[LegoColor?]]) {
        self.width = width
        self.height = height
        self.paletteId = paletteId
        self.cells = cells
    }

    // MARK: - Access

    /// The color at stud `(x, y)`, or `nil` if empty or out of bounds.
    func color(x: Int, y: Int) -> LegoColor? {
        guard y >= 0, y < cells.count, x >= 0, x < cells[y].count else {
            return nil
        }
        return cells[y][x]
    }

    /// Number of non-`nil` (filled) studs. This is the invariant that
    /// brick packing must preserve: Σ brick lengths == `filledStudCount`.
    var filledStudCount: Int {
        cells.reduce(0) { acc, row in
            acc + row.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
        }
    }

    /// Distinct colors present in the grid (excluding `nil`).
    var usedColors: Set<LegoColor> {
        var set = Set<LegoColor>()
        for row in cells {
            for cell in row where cell != nil {
                set.insert(cell!)
            }
        }
        return set
    }

    // MARK: - Validation

    /// `true` when the cell matrix matches the declared `width`/`height`.
    /// Enforced in tests and asserted by the generator before returning.
    var isShapeValid: Bool {
        guard cells.count == height else { return false }
        return cells.allSatisfy { $0.count == width }
    }
}

// MARK: - Presets

/// Square mosaic size presets, in studs. Mirrors the preset table in
/// `docs/LEGO Model Generation System/VISION_PIPELINE.md` §4. The hard
/// cap is 96 studs per side to bound packing/render cost.
enum MosaicGridPreset: Int, CaseIterable, Identifiable {
    case small = 32
    case medium = 48
    case large = 64
    case max = 96

    var id: Int { rawValue }

    /// Side length in studs.
    var studs: Int { rawValue }

    /// Human-facing label, e.g. `"48 × 48"`.
    var label: String { "\(rawValue) × \(rawValue)" }

    /// The maximum allowed studs per side. Used to clamp custom sizes.
    static let maxStudsPerSide = MosaicGridPreset.max.rawValue
}
