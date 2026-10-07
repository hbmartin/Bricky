import Foundation
import simd

/// One pixel where the camera's colour and the authored colour are both
/// known: a completed part, visible and depth-confirmed. Linear light.
struct ColourSample: Sendable, Equatable {
    let observed: SIMD3<Float>
    let expected: SIMD3<Float>
    let code: Int
}

/// In-scene colour calibration (M3.1): the parts already built are the
/// colour chart. A per-channel gain, fitted as the median ratio of authored
/// to observed linear colour, absorbs the white balance and exposure of this
/// room and this camera before the RGB term compares anything.
///
/// RECONSTRUCTED: the colour plane is a gamma-space box mean of the
/// camera's processed image (`ColourGridSampler`), read here as sRGB. The
/// camera's tone mapping is not sRGB and is not undone; a diagonal gain is
/// the simplest model that could work, to be checked on real windows.
enum SceneColourCalibration {
    struct Configuration: Sendable {
        var minimumPixels = 60
        /// One colour cannot separate illuminant from paint.
        var minimumColours = 2
        var minimumPixelsPerColour = 12
        /// Channels this dark carry noise, not a ratio.
        var minimumChannel: Float = 0.02
        var gainRange: ClosedRange<Float> = 0.25...4
    }

    enum Reason: String, Sendable, Equatable {
        case tooFewPixels = "too_few_pixels"
        case tooFewColours = "too_few_colours"
        case implausibleGain = "implausible_gain"
    }

    enum Fit: Sendable, Equatable {
        case calibrated(gain: SIMD3<Float>, pixels: Int, colours: Int)
        case uncalibrated(Reason)

        /// `colour` corrected by the gain, or nil when uncalibrated.
        func apply(_ colour: SIMD3<Float>) -> SIMD3<Float>? {
            guard case .calibrated(let gain, _, _) = self else { return nil }
            return colour * gain
        }
    }

    static func fit(_ samples: [ColourSample], configuration: Configuration = .init()) -> Fit {
        guard samples.count >= configuration.minimumPixels else { return .uncalibrated(.tooFewPixels) }
        var perColour: [Int: Int] = [:]
        for sample in samples { perColour[sample.code, default: 0] += 1 }
        let colours = perColour.values.filter { $0 >= configuration.minimumPixelsPerColour }.count
        guard colours >= configuration.minimumColours else { return .uncalibrated(.tooFewColours) }
        var ratios: [[Float]] = [[], [], []]
        for sample in samples {
            for channel in 0..<3 {
                let observed = sample.observed[channel]
                let expected = sample.expected[channel]
                guard observed >= configuration.minimumChannel, expected >= configuration.minimumChannel else { continue }
                ratios[channel].append(expected / observed)
            }
        }
        let floor = configuration.minimumPixels / 2
        guard ratios.allSatisfy({ $0.count >= floor }) else { return .uncalibrated(.tooFewPixels) }
        let gain = SIMD3(median(ratios[0]), median(ratios[1]), median(ratios[2]))
        guard (0..<3).allSatisfy({ configuration.gainRange.contains(gain[$0]) }) else {
            return .uncalibrated(.implausibleGain)
        }
        return .calibrated(gain: gain, pixels: samples.count, colours: colours)
    }

    static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
