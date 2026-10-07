import simd
import XCTest
@testable import Bricky

/// In-scene gain from the completed parts: it recovers a known per-channel
/// gain, and refuses when the "chart" cannot separate light from paint.
final class SceneColourCalibrationTests: XCTestCase {
    private let red = ColourMath.linear(hex: 0xC91A09)
    private let blue = ColourMath.linear(hex: 0x0055BF)
    private let yellow = ColourMath.linear(hex: 0xF2CD37)

    /// Each expected colour seen through `gain`: observed = expected / gain.
    private func samples(_ colours: [(SIMD3<Float>, Int)], each: Int, gain: SIMD3<Float>) -> [ColourSample] {
        colours.flatMap { colour, code in
            Array(repeating: ColourSample(observed: colour / gain, expected: colour, code: code), count: each)
        }
    }

    func testRecoversAKnownGain() throws {
        let gain = SIMD3<Float>(0.8, 1.0, 1.25)
        let fit = SceneColourCalibration.fit(samples([(red, 4), (blue, 1), (yellow, 14)], each: 30, gain: gain))
        guard case .calibrated(let fitted, let pixels, let colours) = fit else {
            return XCTFail("expected a calibration, got \(fit)")
        }
        XCTAssertEqual(pixels, 90)
        XCTAssertEqual(colours, 3)
        for channel in 0..<3 {
            XCTAssertEqual(fitted[channel], gain[channel], accuracy: 1e-4)
        }
        let corrected = try XCTUnwrap(fit.apply(red / gain))
        XCTAssertEqual(simd_distance(corrected, red), 0, accuracy: 1e-5)
    }

    func testOneColourCannotCalibrate() {
        let fit = SceneColourCalibration.fit(samples([(red, 4)], each: 100, gain: SIMD3(1, 1, 1)))
        XCTAssertEqual(fit, .uncalibrated(.tooFewColours))
        XCTAssertNil(fit.apply(red))
    }

    func testTooFewPixelsCannotCalibrate() {
        XCTAssertEqual(
            SceneColourCalibration.fit(samples([(red, 4), (blue, 1)], each: 20, gain: SIMD3(1, 1, 1))),
            .uncalibrated(.tooFewPixels)
        )
    }

    func testImplausibleGainIsRefused() {
        let fit = SceneColourCalibration.fit(samples([(red, 4), (blue, 1), (yellow, 14)], each: 30, gain: SIMD3(0.1, 1, 1)))
        XCTAssertEqual(fit, .uncalibrated(.implausibleGain))
    }

    func testMedianResistsOutliers() {
        var mixed = samples([(red, 4), (blue, 1), (yellow, 14)], each: 30, gain: SIMD3(1, 1, 1))
        // A specular highlight on a few pixels must not drag the gain.
        mixed += Array(repeating: ColourSample(observed: SIMD3(1, 1, 1), expected: red, code: 4), count: 10)
        guard case .calibrated(let gain, _, _) = SceneColourCalibration.fit(mixed) else {
            return XCTFail("expected a calibration")
        }
        XCTAssertEqual(gain.x, 1, accuracy: 0.05)
    }
}
