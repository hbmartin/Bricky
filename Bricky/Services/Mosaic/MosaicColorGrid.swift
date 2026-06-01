import Foundation

/// The quantized, stud-aligned color grid produced by the vision stage and
/// consumed by brick packing. Faithful port of the backend `ColorGrid`
/// dataclass (`app/contracts.py`).
///
/// `cells` is row-major: `cells.count == height`, `cells[r].count == width`.
/// Each entry is a palette color **name** or `nil` (an omitted/background stud).
struct MosaicColorGrid: Equatable {
    let width: Int
    let height: Int
    let paletteId: String
    /// Row-major grid of palette color names (`nil` = empty stud).
    let cells: [[String?]]
    let warnings: [String]

    init(
        width: Int,
        height: Int,
        paletteId: String,
        cells: [[String?]],
        warnings: [String] = []
    ) {
        self.width = width
        self.height = height
        self.paletteId = paletteId
        self.cells = cells
        self.warnings = warnings
    }

    /// Number of filled (non-empty) studs.
    var studCount: Int {
        cells.reduce(0) { $0 + $1.reduce(0) { $1 == nil ? $0 : $0 + 1 } }
    }
}

// MARK: - Golden-fixture decoding (tests + parity)

extension MosaicColorGrid: Decodable {
    enum CodingKeys: String, CodingKey {
        case width, height, cells, warnings
        case paletteId = "palette_id"
    }
}
