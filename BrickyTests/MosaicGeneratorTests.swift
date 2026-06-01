import XCTest
import UIKit
@testable import Bricky

@MainActor
final class MosaicGeneratorTests: XCTestCase {

    // MARK: - Fixtures

    /// Build an exact `width × height` (points == pixels) image where each
    /// cell is painted with the given `LegoColor`'s catalog hex. At scale 1
    /// with axis-aligned integer rects there is no anti-aliasing, so the
    /// produced bitmap is pixel-exact — ideal for golden-file assertions.
    private func makeImage(cells: [[LegoColor]]) -> UIImage {
        let height = cells.count
        let width = cells.first?.count ?? 0
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            for (y, row) in cells.enumerated() {
                for (x, color) in row.enumerated() {
                    color.uiColorForTest().setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }

    private func solidImage(_ color: LegoColor, side: Int) -> UIImage {
        makeImage(cells: Array(
            repeating: Array(repeating: color, count: side),
            count: side
        ))
    }

    // MARK: - Presets

    func testPresetStudValues() {
        XCTAssertEqual(MosaicGridPreset.small.studs, 32)
        XCTAssertEqual(MosaicGridPreset.medium.studs, 48)
        XCTAssertEqual(MosaicGridPreset.large.studs, 64)
        XCTAssertEqual(MosaicGridPreset.max.studs, 96)
        XCTAssertEqual(MosaicGridPreset.maxStudsPerSide, 96)
    }

    // MARK: - Grid shape & contract

    func testSolidImageProducesUniformGrid() {
        let image = solidImage(.red, side: 100)
        let grid = MosaicGenerator().generate(from: image, preset: .medium)

        let unwrapped = try? XCTUnwrap(grid)
        guard let grid = unwrapped else { return }

        XCTAssertEqual(grid.width, 48)
        XCTAssertEqual(grid.height, 48)
        XCTAssertTrue(grid.isShapeValid)
        XCTAssertEqual(grid.filledStudCount, 48 * 48)
        XCTAssertEqual(grid.usedColors, [.red])
        XCTAssertEqual(grid.paletteId, MosaicGenerator.defaultPaletteId)

        for row in grid.cells {
            for cell in row {
                XCTAssertEqual(cell, .red)
            }
        }
    }

    func testKnownCheckerboardMapsExactly() {
        // 2×2 source painted with catalog hex → 2×2 grid is a 1:1 sample,
        // so each stud must equal the source color exactly.
        let cells: [[LegoColor]] = [
            [.red, .blue],
            [.blue, .red],
        ]
        let image = makeImage(cells: cells)
        let grid = MosaicGenerator().generate(from: image, width: 2, height: 2)

        guard let grid = grid else {
            XCTFail("Expected a grid")
            return
        }
        XCTAssertEqual(grid.color(x: 0, y: 0), .red)
        XCTAssertEqual(grid.color(x: 1, y: 0), .blue)
        XCTAssertEqual(grid.color(x: 0, y: 1), .blue)
        XCTAssertEqual(grid.color(x: 1, y: 1), .red)
    }

    func testRowMajorOrientationTopLeftOrigin() {
        // Top row yellow, bottom row green → cells[0] is the TOP row.
        let cells: [[LegoColor]] = [
            [.yellow, .yellow],
            [.green, .green],
        ]
        let image = makeImage(cells: cells)
        let grid = MosaicGenerator().generate(from: image, width: 2, height: 2)

        XCTAssertEqual(grid?.color(x: 0, y: 0), .yellow)
        XCTAssertEqual(grid?.color(x: 1, y: 0), .yellow)
        XCTAssertEqual(grid?.color(x: 0, y: 1), .green)
        XCTAssertEqual(grid?.color(x: 1, y: 1), .green)
    }

    // MARK: - Determinism

    func testGenerationIsDeterministic() {
        let cells: [[LegoColor]] = [
            [.red, .blue, .yellow],
            [.green, .black, .white],
            [.orange, .tan, .lime],
        ]
        let image = makeImage(cells: cells)
        let gen = MosaicGenerator()

        let first = gen.generate(from: image, width: 3, height: 3)
        let second = gen.generate(from: image, width: 3, height: 3)
        XCTAssertEqual(first, second)
    }

    // MARK: - Bounds

    func testZeroAndOversizeDimensionsReturnNil() {
        let image = solidImage(.red, side: 10)
        let gen = MosaicGenerator()
        XCTAssertNil(gen.generate(from: image, width: 0, height: 10))
        XCTAssertNil(gen.generate(from: image, width: 10, height: 0))
        XCTAssertNil(gen.generate(from: image, width: 97, height: 10))
        XCTAssertNil(gen.generate(from: image, width: 10, height: 97))
    }

    // MARK: - Geometry helpers

    func testCoverFitRectLandscapeSourceIntoSquare() {
        // 200×100 into 50×50 → scale = max(0.25, 0.5) = 0.5 → 100×50,
        // centered horizontally (x = -25), full height.
        let rect = MosaicGenerator.coverFitRect(
            source: CGSize(width: 200, height: 100),
            target: CGSize(width: 50, height: 50)
        )
        XCTAssertEqual(rect.width, 100, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 50, accuracy: 0.0001)
        XCTAssertEqual(rect.origin.x, -25, accuracy: 0.0001)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.0001)
    }

    func testCoverFitRectSquareSourceIsIdentity() {
        let rect = MosaicGenerator.coverFitRect(
            source: CGSize(width: 64, height: 64),
            target: CGSize(width: 32, height: 32)
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 32, height: 32))
    }

    func testFittedDimensionsPreservesAspectAndClamps() {
        let landscape = MosaicGenerator.fittedDimensions(
            for: CGSize(width: 200, height: 100), maxStuds: 48)
        XCTAssertEqual(landscape.width, 48)
        XCTAssertEqual(landscape.height, 24)

        let portrait = MosaicGenerator.fittedDimensions(
            for: CGSize(width: 100, height: 200), maxStuds: 48)
        XCTAssertEqual(portrait.width, 24)
        XCTAssertEqual(portrait.height, 48)

        // Clamp to the 96-stud cap.
        let clamped = MosaicGenerator.fittedDimensions(
            for: CGSize(width: 500, height: 500), maxStuds: 1000)
        XCTAssertEqual(clamped.width, 96)
        XCTAssertEqual(clamped.height, 96)
    }

    // MARK: - Out-of-bounds access

    func testColorAccessOutOfBoundsIsNil() {
        let grid = MosaicGenerator().generate(
            from: solidImage(.red, side: 4), width: 4, height: 4)
        XCTAssertNil(grid?.color(x: -1, y: 0))
        XCTAssertNil(grid?.color(x: 0, y: -1))
        XCTAssertNil(grid?.color(x: 4, y: 0))
        XCTAssertNil(grid?.color(x: 0, y: 4))
    }
}

// MARK: - Test color helper

private extension LegoColor {
    /// A `UIColor` built from the catalog `hex` value (no alpha), used to
    /// paint pixel-exact fixtures.
    func uiColorForTest() -> UIColor {
        let value = hex
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}
