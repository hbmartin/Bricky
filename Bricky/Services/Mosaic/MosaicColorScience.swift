import Foundation

/// Color science for the on-device mosaic engine.
///
/// This is a faithful 1:1 port of the backend `app/colorspace.py`
/// (`services/lego-model-gen`). It converts sRGB → linear → CIE XYZ → CIELAB
/// using the D65 reference white and computes CIE76 (Euclidean LAB) distance,
/// which is the deterministic default the backend uses for grid quantization.
///
/// Keeping the math identical to the Python reference is what lets the Swift
/// pipeline reproduce the backend's golden fixtures byte-for-byte.
enum MosaicColorScience {

    /// A CIELAB color. Component order matches `(L*, a*, b*)`.
    struct Lab: Equatable {
        let l: Double
        let a: Double
        let b: Double
    }

    // D65 reference white (2° observer), identical to `_XN, _YN, _ZN`.
    private static let xn = 0.95047
    private static let yn = 1.0
    private static let zn = 1.08883

    /// sRGB component in `[0, 1]` → linear-light RGB in `[0, 1]`.
    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Linear-light RGB component in `[0, 1]` → sRGB in `[0, 1]`.
    static func linearToSrgb(_ c: Double) -> Double {
        let v = min(max(c, 0.0), 1.0)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    /// sRGB triplet in `[0, 1]` → CIELAB.
    static func srgbToLab(r: Double, g: Double, b: Double) -> Lab {
        let rl = srgbToLinear(r)
        let gl = srgbToLinear(g)
        let bl = srgbToLinear(b)

        // Linear RGB → XYZ (IEC 61966-2-1, D65).
        let x = 0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl
        let y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
        let z = 0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl

        let fx = labF(x / xn)
        let fy = labF(y / yn)
        let fz = labF(z / zn)

        return Lab(
            l: 116 * fy - 16,
            a: 500 * (fx - fy),
            b: 200 * (fy - fz)
        )
    }

    private static func labF(_ t: Double) -> Double {
        let delta = 6.0 / 29.0
        return t > delta * delta * delta
            ? cbrt(t)
            : t / (3 * delta * delta) + 4.0 / 29.0
    }

    /// CIE76 (Euclidean) distance between two LAB colors.
    static func deltaE76(_ lhs: Lab, _ rhs: Lab) -> Double {
        let dl = lhs.l - rhs.l
        let da = lhs.a - rhs.a
        let db = lhs.b - rhs.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}
