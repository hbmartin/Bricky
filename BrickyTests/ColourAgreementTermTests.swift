import simd
import XCTest
@testable import Bricky

/// Mechanics of the colour term on ideal colour painted from the tag maps.
/// There is deliberately no noise model: no synthetic colour sensor exists
/// or may be invented (ADR 0008, ADR 0014), so nothing here tunes a
/// threshold. Real windows do that in Phase 1.
final class ColourAgreementTermTests: XCTestCase {
    private let width = 32
    private let height = 20
    private let red = 4, blue = 1, yellow = 14, clear = 47

    private var table: ColourTable {
        ColourTable(definitions: [
            red: .init(code: red, name: "Red", rgb: 0xC91A09, edgeRGB: nil, alpha: 255, finish: .plastic),
            blue: .init(code: blue, name: "Blue", rgb: 0x0055BF, edgeRGB: nil, alpha: 255, finish: .plastic),
            yellow: .init(code: yellow, name: "Yellow", rgb: 0xF2CD37, edgeRGB: nil, alpha: 255, finish: .plastic),
            clear: .init(code: clear, name: "Trans_Clear", rgb: 0xFCFCFC, edgeRGB: nil, alpha: 128, finish: .plastic)
        ])
    }

    private func term(billOfMaterials: [Int]? = nil) -> ColourAgreementTerm {
        ColourAgreementTerm(table: table, billOfMaterials: billOfMaterials ?? [red, blue, yellow])
    }

    /// Completed parts fill rows 2…17: `left` in columns 2…15, `right` in
    /// 16…29, at 0.50 m. The step's delta is a block in front at 0.49 m.
    /// The camera sees `seen` on the delta (or what is behind when the
    /// delta is absent), every colour divided by `gain` in linear light.
    private func frame(
        authored: Int, seen: Int? = nil, left: Int? = nil, right: Int? = nil,
        deltaColumns: ClosedRange<Int> = 12...19, present: Bool = true,
        gain: SIMD3<Float> = SIMD3(1, 1, 1), colour: Bool = true
    ) -> ColourFrame {
        let left = left ?? blue, right = right ?? yellow
        let count = width * height
        var completedDepth = [Float32](repeating: 0, count: count)
        var completedTags = [UInt32](repeating: 0, count: count)
        var deltaDepth = [Float32](repeating: 0, count: count)
        var deltaTags = [UInt32](repeating: 0, count: count)
        var observedDepth = [Float32](repeating: 0.8, count: count)
        var pixels = [UInt8](repeating: 128, count: count * 3)
        for y in 2...17 {
            for x in 2...29 {
                let index = y * width + x
                let code = x <= 15 ? left : right
                completedDepth[index] = 0.5
                completedTags[index] = ExpectedDepthRenderer.tag(for: code)
                observedDepth[index] = 0.5
                paint(&pixels, index, code: code, gain: gain)
            }
        }
        for y in 6...11 {
            for x in deltaColumns {
                let index = y * width + x
                deltaDepth[index] = 0.49
                deltaTags[index] = ExpectedDepthRenderer.tag(for: authored)
                if present {
                    observedDepth[index] = 0.49
                    paint(&pixels, index, code: seen ?? authored, gain: gain)
                }
            }
        }
        return ColourFrame(
            colour: colour ? pixels : [], observedDepth: observedDepth,
            observedConfidence: [UInt8](repeating: 2, count: count),
            completedDepth: completedDepth, completedTags: completedTags,
            deltaDepth: deltaDepth, deltaTags: deltaTags, width: width, height: height
        )
    }

    private func paint(_ pixels: inout [UInt8], _ index: Int, code: Int, gain: SIMD3<Float>) {
        guard let linear = table.entry(for: code).linear else { return }
        let seen = linear / gain
        for channel in 0..<3 {
            pixels[index * 3 + channel] = Self.encode(seen[channel])
        }
    }

    /// Linear light back to 8-bit sRGB.
    private static func encode(_ linear: Float) -> UInt8 {
        let clamped = min(max(linear, 0), 1)
        let srgb = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * Float(pow(Double(clamped), 1 / 2.4)) - 0.055
        return UInt8((srgb * 255).rounded())
    }

    private func assess(_ frames: [ColourFrame], term: ColourAgreementTerm? = nil) -> ColourAssessment {
        let term = term ?? self.term()
        return term.assess(frames.map { term.evidence(from: $0) })
    }

    func testTheAuthoredColourAgrees() throws {
        let assessment = assess(Array(repeating: frame(authored: red), count: 3))
        XCTAssertEqual(assessment.status, .agrees)
        let group = try XCTUnwrap(assessment.groups.first)
        XCTAssertEqual(group.code, red)
        XCTAssertEqual(group.frames, 3)
        XCTAssertEqual(try XCTUnwrap(group.authoredDistance), 0, accuracy: 0.01)
        XCTAssertEqual(assessment.framesCalibrated, 3)
    }

    func testASwappedColourDisagreesAndNamesIt() {
        let assessment = assess(Array(repeating: frame(authored: red, seen: blue), count: 3))
        XCTAssertEqual(assessment.status, .disagrees(nearestCode: blue))
    }

    func testAColourLikeWhatIsBeneathCannotCorroborate() {
        // Red over red: an absent part would look the same.
        let frames = Array(repeating: frame(authored: red, right: red, deltaColumns: 19...26), count: 3)
        XCTAssertEqual(assess(frames).status, .inconclusive(.nonDiscriminative))
    }

    func testATransparentPartIsUnobservable() {
        let frames = Array(repeating: frame(authored: clear), count: 3)
        XCTAssertEqual(assess(frames, term: term(billOfMaterials: [red, blue, yellow, clear])).status,
                       .inconclusive(.unobservableFinish))
    }

    func testCalibrationAbsorbsAGlobalCast() throws {
        // A warm room: blue suppressed, red boosted, in linear light.
        let gain = SIMD3<Float>(0.75, 1.0, 1.4)
        let assessment = assess(Array(repeating: frame(authored: red, gain: gain), count: 3))
        XCTAssertEqual(assessment.status, .agrees)
        // 8-bit quantization of red's near-black channels under the cast
        // leaves a few hundredths, well inside the agree ceiling.
        XCTAssertLessThan(try XCTUnwrap(assessment.groups.first?.authoredDistance), 0.05)
    }

    func testOneColourChartCannotCalibrate() {
        let frames = Array(repeating: frame(authored: red, left: blue, right: blue), count: 3)
        XCTAssertEqual(assess(frames).status, .inconclusive(.uncalibrated))
    }

    func testNoColourPlaneIsNoEvidence() {
        let frames = Array(repeating: frame(authored: red, colour: false), count: 3)
        let assessment = assess(frames)
        XCTAssertEqual(assessment.status, .inconclusive(.noColour))
        XCTAssertEqual(assessment.framesWithColour, 0)
    }

    func testTooFewFramesWaits() {
        XCTAssertEqual(assess(Array(repeating: frame(authored: red), count: 2)).status, .inconclusive(.tooFewFrames))
    }

    func testOnlyDepthConfirmedPixelsCount() {
        // Absent delta: the depth there is the completed surface, 1 cm
        // behind, so no delta pixel is confirmed and colour says nothing.
        let assessment = assess(Array(repeating: frame(authored: red, present: false), count: 3))
        XCTAssertEqual(assessment.groups.first(where: { $0.code == red })?.pixels ?? 0, 0)
        XCTAssertNotEqual(assessment.status, .agrees)
    }

    func testTheDeltaRegionIsErodedByAPixel() {
        let term = term()
        let region = term.deltaRegion(frame(authored: red))
        // A 6 × 8 block keeps its 4 × 6 interior.
        XCTAssertEqual(region.count, 24)
        XCTAssertFalse(region.contains(6 * width + 12), "the block's corner is an edge")
        XCTAssertTrue(region.contains(7 * width + 13))
    }
}
