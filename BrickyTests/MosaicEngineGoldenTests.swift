import XCTest
@testable import Bricky

/// Golden-parity tests for the on-device mosaic engine
/// (`Bricky/Services/Mosaic/`).
///
/// These lock the deterministic core of the engine byte-for-byte against the
/// fixtures captured from the retired `services/lego-model-gen` Python backend
/// (`tests/golden/`). The fixtures are copied into `BrickyTests/Golden/` and
/// read directly from the source tree via `#filePath` — the iOS Simulator runs
/// on the host Mac and can read these paths without bundling them as resources.
///
/// Per the project's "untrusted artifacts" rule, the engine is considered valid
/// only because these executable tests reproduce the backend's golden output.
final class MosaicEngineGoldenTests: XCTestCase {

    // MARK: - Fixture Loading

    private static func goldenDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Golden", isDirectory: true)
    }

    private func goldenData(_ name: String) throws -> Data {
        let url = Self.goldenDirectory().appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private func goldenString(_ name: String) throws -> String {
        let url = Self.goldenDirectory().appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The golden grid, decoded into the engine's own grid type.
    private func loadGoldenGrid() throws -> MosaicColorGrid {
        try JSONDecoder().decode(MosaicColorGrid.self, from: goldenData("grid.json"))
    }

    // MARK: - Color Science

    func testSrgbToLinearReference() {
        XCTAssertEqual(
            MosaicColorScience.srgbToLinear(0.5),
            0.21404114048223255,
            accuracy: 1e-12
        )
    }

    func testSrgbToLabReferenceValues() {
        func lab(_ hex: UInt32) -> MosaicColorScience.Lab {
            let r = Double((hex >> 16) & 0xFF) / 255.0
            let g = Double((hex >> 8) & 0xFF) / 255.0
            let b = Double(hex & 0xFF) / 255.0
            return MosaicColorScience.srgbToLab(r: r, g: g, b: b)
        }

        let cases: [(UInt32, Double, Double, Double)] = [
            (0xC91A09, 43.033548, 63.794596, 53.710074),   // Bright Red
            (0x237841, 44.477192, -38.289106, 23.042373),  // Bright Green
            (0xFFFFFF, 100.000004, -0.000017, 0.000007),   // White
            (0x808080, 53.585016, -0.000010, 0.000004),    // Mid gray
            (0x36AEBF, 65.604303, -26.929555, -18.222884), // Medium Azure
        ]

        for (hex, l, a, b) in cases {
            let result = lab(hex)
            XCTAssertEqual(result.l, l, accuracy: 1e-4, "L for \(String(hex, radix: 16))")
            XCTAssertEqual(result.a, a, accuracy: 1e-4, "a for \(String(hex, radix: 16))")
            XCTAssertEqual(result.b, b, accuracy: 1e-4, "b for \(String(hex, radix: 16))")
        }
    }

    // MARK: - Palette

    func testPaletteLoadsFourteenColors() throws {
        let palette = try MosaicPalette.load()
        XCTAssertEqual(palette.paletteId, "mvp-v1")
        XCTAssertEqual(palette.colors.count, 14)
        // Spot-check a color carries the right LDraw/BrickLink/Rebrickable ids.
        let black = try XCTUnwrap(palette.color(named: "Black"))
        XCTAssertEqual(black.ldraw, 0)
        XCTAssertEqual(black.bricklink, 11)
        XCTAssertEqual(black.rebrickable, 0)
    }

    // MARK: - Grid Decoding

    func testGoldenGridDecodes() throws {
        let grid = try loadGoldenGrid()
        XCTAssertEqual(grid.width, 32)
        XCTAssertEqual(grid.height, 32)
        XCTAssertEqual(grid.paletteId, "mvp-v1")
        XCTAssertEqual(grid.cells.count, 32)
        XCTAssertEqual(grid.cells[0].count, 32)
        XCTAssertEqual(grid.cells[0][0], "Black")
    }

    // MARK: - Packer Parity

    func testPackerMatchesGoldenBricks() throws {
        struct GoldenBrick: Decodable, Equatable {
            let x: Int
            let y: Int
            let length: Int
            let color: String
            let part: String
        }

        let grid = try loadGoldenGrid()
        let bricks = MosaicPacker.pack(grid)

        let expected = try JSONDecoder().decode([GoldenBrick].self, from: goldenData("bricks.json"))

        XCTAssertEqual(bricks.count, expected.count)
        for (index, exp) in expected.enumerated() {
            let actual = bricks[index]
            XCTAssertEqual(actual.x, exp.x, "brick \(index) x")
            XCTAssertEqual(actual.y, exp.y, "brick \(index) y")
            XCTAssertEqual(actual.length, exp.length, "brick \(index) length")
            XCTAssertEqual(actual.color, exp.color, "brick \(index) color")
            XCTAssertEqual(actual.part, exp.part, "brick \(index) part")
        }
    }

    // MARK: - LDraw Exporter Parity

    func testExporterMatchesGoldenLDR() throws {
        let palette = try MosaicPalette.load()
        let grid = try loadGoldenGrid()
        let bricks = MosaicPacker.pack(grid)

        let ldr = MosaicLDRExporter.export(bricks, palette: palette)
        let expected = try goldenString("model.ldr")

        XCTAssertEqual(ldr, expected)
    }

    // MARK: - Parts Aggregator Parity

    func testAggregatorMatchesGoldenParts() throws {
        let palette = try MosaicPalette.load()
        let grid = try loadGoldenGrid()
        let bricks = MosaicPacker.pack(grid)

        let parts = MosaicPartsAggregator.aggregate(bricks, palette: palette)
        let expected = try JSONDecoder().decode(MosaicPartsList.self, from: goldenData("parts.json"))

        XCTAssertEqual(parts.paletteId, expected.paletteId)
        XCTAssertEqual(parts.totalParts, expected.totalParts)
        XCTAssertEqual(parts.parts.count, expected.parts.count)
        for (index, exp) in expected.parts.enumerated() {
            XCTAssertEqual(parts.parts[index], exp, "part line \(index)")
        }
    }
}
