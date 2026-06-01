import XCTest
import UIKit
@testable import Bricky

/// Tests for the on-device mosaic vision stage and end-to-end engine.
///
/// The vision stage is a best-effort Core Graphics port of the backend's PIL
/// pipeline, so it is NOT locked to the golden fixtures (the deterministic core
/// is — see `MosaicEngineGoldenTests`). Instead we assert the properties that
/// must hold regardless of resampler: determinism and correct quantization of a
/// known solid color.
final class MosaicVisionTests: XCTestCase {

    /// A solid-color image of the given size.
    private func solidImage(_ color: UIColor, size: CGSize = CGSize(width: 256, height: 256)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testSolidColorQuantizesToNearestPaletteName() throws {
        let palette = try MosaicPalette.load()
        // Bright Red == C91A09.
        let image = solidImage(UIColor(red: 0xC9 / 255.0, green: 0x1A / 255.0, blue: 0x09 / 255.0, alpha: 1))

        let grid = MosaicVision.buildGrid(image: image, width: 16, height: 16, palette: palette)

        XCTAssertEqual(grid.width, 16)
        XCTAssertEqual(grid.height, 16)
        for row in grid.cells {
            for cell in row {
                XCTAssertEqual(cell, "Bright Red")
            }
        }
    }

    func testVisionIsDeterministic() throws {
        let palette = try MosaicPalette.load()
        let image = solidImage(UIColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))

        let a = MosaicVision.buildGrid(image: image, width: 24, height: 24, palette: palette)
        let b = MosaicVision.buildGrid(image: image, width: 24, height: 24, palette: palette)

        XCTAssertEqual(a, b)
    }

    func testSolidGridWarnsLowDetail() throws {
        let palette = try MosaicPalette.load()
        let image = solidImage(.black)

        let grid = MosaicVision.buildGrid(image: image, width: 16, height: 16, palette: palette)

        XCTAssertTrue(grid.warnings.contains("low_detail"))
    }
}

/// End-to-end tests for `MosaicEngine`, exercising the full on-device pipeline.
final class MosaicEngineTests: XCTestCase {

    private func solidImage(_ color: UIColor) -> UIImage {
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Thread-safe sink for the `@Sendable` progress callback.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [Double] = []
        func record(_ value: Double) {
            lock.lock(); defer { lock.unlock() }
            values.append(value)
        }
    }

    func testGenerateProducesCompleteOutput() throws {
        let image = solidImage(UIColor(red: 0xC9 / 255.0, green: 0x1A / 255.0, blue: 0x09 / 255.0, alpha: 1))

        let recorder = ProgressRecorder()
        let output = try MosaicEngine.shared.generate(
            image: image,
            width: 16,
            height: 16
        ) { recorder.record($0) }

        // A fully covered 16×16 mosaic.
        XCTAssertEqual(output.studCount, 16 * 16)
        XCTAssertEqual(output.snappedGrid.width, 16)
        XCTAssertEqual(output.snappedGrid.height, 16)
        XCTAssertGreaterThan(output.brickCount, 0)
        XCTAssertEqual(output.bricks.count, output.brickCount)

        // Solid red → every plate is Bright Red.
        XCTAssertTrue(output.bricks.allSatisfy { $0.color == "Bright Red" })

        // Artifacts are real, non-empty payloads.
        XCTAssertFalse(output.ldrText.isEmpty)
        XCTAssertTrue(output.ldrText.contains("3023.dat") || output.ldrText.contains("3710.dat"))
        XCTAssertFalse(output.pdfData.isEmpty)
        XCTAssertEqual(output.parts.paletteId, "mvp-v1")
        XCTAssertEqual(output.parts.totalParts, output.brickCount)

        // Progress is monotonic and reaches 1.0.
        let progressValues = recorder.values
        XCTAssertEqual(progressValues.last, 1.0)
        XCTAssertEqual(progressValues, progressValues.sorted())
    }

    func testGenerateRejectsInvalidGridSize() {
        let image = solidImage(.black)
        XCTAssertThrowsError(try MosaicEngine.shared.generate(image: image, width: 0, height: 16))
    }
}
