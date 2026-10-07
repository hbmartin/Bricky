import simd
import XCTest
@testable import Bricky

/// The expected-colour side of the RGB term: sRGB → linear → Oklab against
/// published reference values, and which finishes a camera cannot judge.
final class ColourTableTests: XCTestCase {
    private func definition(
        _ code: Int, rgb: UInt32, alpha: UInt8 = 255, finish: LDrawColorDefinition.Finish = .plastic
    ) -> LDrawColorDefinition {
        LDrawColorDefinition(code: code, name: "C\(code)", rgb: rgb, edgeRGB: nil, alpha: alpha, finish: finish)
    }

    func testTransferFunctionMatchesSRGB() {
        XCTAssertEqual(ColourMath.linear(srgb: 0), 0)
        XCTAssertEqual(ColourMath.linear(srgb: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(ColourMath.linear(srgb: 0.5), 0.21404, accuracy: 1e-4)
        XCTAssertEqual(ColourMath.linear(srgb: 0.04), 0.04 / 12.92, accuracy: 1e-7)
    }

    func testOklabMatchesReferenceValues() {
        let white = ColourMath.oklab(linear: SIMD3(1, 1, 1))
        XCTAssertEqual(white.x, 1, accuracy: 1e-3)
        XCTAssertEqual(white.y, 0, accuracy: 1e-3)
        XCTAssertEqual(white.z, 0, accuracy: 1e-3)
        XCTAssertEqual(ColourMath.oklab(linear: .zero), .zero)
        // Ottosson's published value for linear sRGB red.
        let red = ColourMath.oklab(linear: SIMD3(1, 0, 0))
        XCTAssertEqual(red.x, 0.62796, accuracy: 1e-3)
        XCTAssertEqual(red.y, 0.22486, accuracy: 1e-3)
        XCTAssertEqual(red.z, 0.12585, accuracy: 1e-3)
    }

    func testDistinctBrickColoursAreFarApartInOklab() throws {
        let table = ColourTable(definitions: [
            4: definition(4, rgb: 0xC91A09), 1: definition(1, rgb: 0x0055BF), 320: definition(320, rgb: 0x720E0F)
        ])
        let red = try XCTUnwrap(table.entry(for: 4).oklab)
        let blue = try XCTUnwrap(table.entry(for: 1).oklab)
        let darkRed = try XCTUnwrap(table.entry(for: 320).oklab)
        XCTAssertGreaterThan(ColourMath.distance(red, blue), 0.3)
        XCTAssertGreaterThan(ColourMath.distance(red, darkRed), 0.1)
    }

    func testFinishesACameraCannotJudgeAreUnobservable() {
        let table = ColourTable(definitions: [
            40: definition(40, rgb: 0x635F52, alpha: 128),
            383: definition(383, rgb: 0xE0E0E0, finish: .chrome),
            183: definition(183, rgb: 0xF2F3F2, finish: .pearlescent),
            80: definition(80, rgb: 0x767676, finish: .metal),
            135: definition(135, rgb: 0xA0A0A0, finish: .matteMetallic),
            132: definition(132, rgb: 0x000000, finish: .material),
            256: definition(256, rgb: 0x212121, finish: .rubber)
        ])
        XCTAssertEqual(table.entry(for: 40), .unobservable(.transparent))
        XCTAssertEqual(table.entry(for: 383), .unobservable(.chrome))
        XCTAssertEqual(table.entry(for: 183), .unobservable(.pearlescent))
        XCTAssertEqual(table.entry(for: 80), .unobservable(.metal))
        XCTAssertEqual(table.entry(for: 135), .unobservable(.matteMetallic))
        XCTAssertEqual(table.entry(for: 132), .unobservable(.material))
        XCTAssertNotNil(table.entry(for: 256).oklab, "rubber is matte and observable")
        XCTAssertEqual(table.entry(for: 9999), .unobservable(.unknown))
        XCTAssertEqual(table.entry(for: 0x3000001), .unobservable(.dithered))
    }

    func testDirectColoursAreObservableWithoutThePalette() throws {
        let table = ColourTable(definitions: [:])
        let direct = try XCTUnwrap(table.entry(for: 0x2FF0000).linear)
        XCTAssertEqual(direct, SIMD3(1, 0, 0))
    }
}
