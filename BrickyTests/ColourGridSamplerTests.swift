import XCTest
@testable import Bricky

/// Colour evidence must mean the same thing whatever matrix and range the
/// camera reports, or an RGB term trained on it learns the encoding.
final class ColourGridSamplerTests: XCTestCase {
    private func assertRGB(
        _ actual: (UInt8, UInt8, UInt8), _ expected: (Int, Int, Int), tolerance: Int = 2,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(abs(Int(actual.0) - expected.0), tolerance, "r", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(actual.1) - expected.1), tolerance, "g", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(actual.2) - expected.2), tolerance, "b", file: file, line: line)
    }

    func testPureRedUnderBothMatrices() {
        // Full-range encodings of (255, 0, 0).
        assertRGB(ColourGridSampler.convert(y: 54.2, cb: 98.8, cr: 255, matrix: .bt709, range: .full), (255, 0, 0))
        assertRGB(ColourGridSampler.convert(y: 76.2, cb: 85.0, cr: 255, matrix: .bt601, range: .full), (255, 0, 0))
        // The same bytes read with the wrong matrix are visibly wrong: the
        // encoding has to be recorded.
        let misread = ColourGridSampler.convert(y: 54.2, cb: 98.8, cr: 255, matrix: .bt601, range: .full)
        XCTAssertGreaterThan(abs(Int(misread.0) - 255), 10)
    }

    func testVideoRangeEndpoints() {
        assertRGB(ColourGridSampler.convert(y: 16, cb: 128, cr: 128, matrix: .bt709, range: .video), (0, 0, 0), tolerance: 0)
        assertRGB(ColourGridSampler.convert(y: 235, cb: 128, cr: 128, matrix: .bt709, range: .video), (255, 255, 255), tolerance: 0)
        assertRGB(ColourGridSampler.convert(y: 128, cb: 128, cr: 128, matrix: .bt601, range: .full), (128, 128, 128), tolerance: 0)
    }

    func testEachCellIsTheMeanOfItsFootprint() {
        // 4×2 luma: left half 50, right half 200; neutral chroma.
        let luma: [UInt8] = [50, 50, 200, 200, 50, 50, 200, 200]
        let chroma: [UInt8] = [128, 128, 128, 128]
        let rgb = luma.withUnsafeBytes { lumaBytes in
            chroma.withUnsafeBytes { chromaBytes in
                ColourGridSampler.sample(
                    luma: .init(base: lumaBytes.baseAddress!, width: 4, height: 2, bytesPerRow: 4),
                    chroma: .init(base: chromaBytes.baseAddress!, width: 2, height: 1, bytesPerRow: 4),
                    matrix: .bt709, range: .full, gridWidth: 2, gridHeight: 1, step: 1
                )
            }
        }
        XCTAssertEqual(rgb, [50, 50, 50, 200, 200, 200])
        XCTAssertEqual(ColourGridSampler.encoding(matrix: .bt709, range: .full), "rgb8_bt709_full")
    }
}
