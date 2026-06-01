import Foundation

/// A single LEGO color in a mosaic palette, mirroring the backend
/// `app/palette.py` `Color` dataclass plus the columns of `data/colors.csv`.
struct MosaicPaletteColor: Equatable {
    let name: String
    let ldraw: Int
    let bricklink: Int
    let rebrickable: Int
    /// 0–255 sRGB components.
    let red: Int
    let green: Int
    let blue: Int
}

/// An ordered, immutable LEGO color palette with cached CIELAB coordinates.
///
/// Faithful port of the backend `Palette` class. Numeric IDs and RGB values
/// come only from the bundled palette JSON (the on-device equivalent of
/// `data/colors.csv`) — never hand-entered in logic. Quantization maps an sRGB
/// cell color to the perceptually nearest palette color in CIELAB using CIE76,
/// matching the backend's deterministic default.
struct MosaicPalette {

    enum PaletteError: LocalizedError {
        case resourceMissing(String)
        case decodingFailed(String)
        case empty

        var errorDescription: String? {
            switch self {
            case let .resourceMissing(id):
                return "Mosaic palette resource '\(id)' is missing from the app bundle."
            case let .decodingFailed(detail):
                return "Failed to decode mosaic palette: \(detail)"
            case .empty:
                return "Mosaic palette must contain at least one color."
            }
        }
    }

    let paletteId: String
    let colors: [MosaicPaletteColor]

    private let byName: [String: MosaicPaletteColor]
    private let labs: [MosaicColorScience.Lab]

    init(paletteId: String, colors: [MosaicPaletteColor]) throws {
        guard !colors.isEmpty else { throw PaletteError.empty }
        self.paletteId = paletteId
        self.colors = colors
        self.byName = Dictionary(uniqueKeysWithValues: colors.map { ($0.name, $0) })
        self.labs = colors.map {
            MosaicColorScience.srgbToLab(
                r: Double($0.red) / 255.0,
                g: Double($0.green) / 255.0,
                b: Double($0.blue) / 255.0
            )
        }
    }

    var names: [String] { colors.map(\.name) }

    func color(named name: String) -> MosaicPaletteColor? { byName[name] }

    /// Return the palette color name nearest to a single sRGB `[0, 1]` color,
    /// using CIE76 distance. Ties resolve to the first color in palette order
    /// (matching numpy's `argmin`).
    func nearestName(r: Double, g: Double, b: Double) -> String {
        let target = MosaicColorScience.srgbToLab(r: r, g: g, b: b)
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, lab) in labs.enumerated() {
            let distance = MosaicColorScience.deltaE76(target, lab)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return colors[bestIndex].name
    }
}

// MARK: - Bundled Palette Loading

extension MosaicPalette {

    private struct PaletteFile: Decodable {
        struct Entry: Decodable {
            let name: String
            let ldraw: Int
            let bricklink: Int
            let rebrickable: Int
            let rgb: String
        }
        let paletteId: String
        let colors: [Entry]

        enum CodingKeys: String, CodingKey {
            case paletteId = "palette_id"
            case colors
        }
    }

    /// The default MVP palette identifier (matches the backend
    /// `DEFAULT_PALETTE_ID`).
    static let defaultPaletteId = "mvp-v1"

    /// Load and cache a bundled palette by id. The MVP ships `mvp-v1`.
    static func load(_ paletteId: String = defaultPaletteId, bundle: Bundle = .main) throws -> MosaicPalette {
        if let cached = cache[paletteId] { return cached }

        let resourceName = "mosaic-palette-\(paletteId)"
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw PaletteError.resourceMissing(paletteId)
        }

        let data = try Data(contentsOf: url)
        let file: PaletteFile
        do {
            file = try JSONDecoder().decode(PaletteFile.self, from: data)
        } catch {
            throw PaletteError.decodingFailed(error.localizedDescription)
        }

        let colors = try file.colors.map { entry -> MosaicPaletteColor in
            let (r, g, b) = try parseHex(entry.rgb)
            return MosaicPaletteColor(
                name: entry.name,
                ldraw: entry.ldraw,
                bricklink: entry.bricklink,
                rebrickable: entry.rebrickable,
                red: r,
                green: g,
                blue: b
            )
        }

        let palette = try MosaicPalette(paletteId: file.paletteId, colors: colors)
        cache[paletteId] = palette
        return palette
    }

    /// Process-wide cache (palettes are immutable once published).
    nonisolated(unsafe) private static var cache: [String: MosaicPalette] = [:]

    private static func parseHex(_ raw: String) throws -> (Int, Int, Int) {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            throw PaletteError.decodingFailed("invalid rgb hex '\(raw)'")
        }
        return (
            Int((value >> 16) & 0xFF),
            Int((value >> 8) & 0xFF),
            Int(value & 0xFF)
        )
    }
}
