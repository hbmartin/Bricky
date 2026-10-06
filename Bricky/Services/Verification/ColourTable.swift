import Foundation
import simd

/// Colour arithmetic for the RGB term (ADR 0008, M3.1): sRGB to linear light
/// to Oklab, where Euclidean distance tracks perceived difference.
enum ColourMath {
    /// The sRGB transfer function's inverse, for one channel in 0...1.
    static func linear(srgb channel: Float) -> Float {
        channel <= 0.04045 ? channel / 12.92 : Float(pow(Double((channel + 0.055) / 1.055), 2.4))
    }

    static func linear(rgb8 red: UInt8, _ green: UInt8, _ blue: UInt8) -> SIMD3<Float> {
        SIMD3(linear(srgb: Float(red) / 255), linear(srgb: Float(green) / 255), linear(srgb: Float(blue) / 255))
    }

    /// `0xRRGGBB` as linear light.
    static func linear(hex: UInt32) -> SIMD3<Float> {
        linear(rgb8: UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }

    /// Björn Ottosson's Oklab, from linear sRGB.
    static func oklab(linear rgb: SIMD3<Float>) -> SIMD3<Float> {
        let l = 0.4122214708 * rgb.x + 0.5363325363 * rgb.y + 0.0514459929 * rgb.z
        let m = 0.2119034982 * rgb.x + 0.6806995451 * rgb.y + 0.1073969566 * rgb.z
        let s = 0.0883024619 * rgb.x + 0.2817188376 * rgb.y + 0.6299787005 * rgb.z
        let lRoot = Float(cbrt(Double(max(l, 0))))
        let mRoot = Float(cbrt(Double(max(m, 0))))
        let sRoot = Float(cbrt(Double(max(s, 0))))
        let lightness = 0.2104542553 * lRoot + 0.7936177850 * mRoot - 0.0040720468 * sRoot
        let a = 1.9779984951 * lRoot - 2.4285922050 * mRoot + 0.4505937099 * sRoot
        let b = 0.0259040371 * lRoot + 0.7827717662 * mRoot - 0.8086757660 * sRoot
        return SIMD3(lightness, a, b)
    }

    /// Distance in Oklab: about 0.02 is a just-noticeable difference.
    static func distance(_ first: SIMD3<Float>, _ second: SIMD3<Float>) -> Float {
        simd_distance(first, second)
    }
}

/// What the RGB term may expect to see for each LDraw colour code: its
/// authored colour, or the reason no camera can confirm it. Built from the
/// installed `LDConfig.ldr` (Foundation-only, so SyntheticRGBD compiles it).
struct ColourTable: Sendable {
    /// Why a colour cannot be judged from a camera's colour plane.
    enum Unobservable: String, Sendable, Equatable {
        /// Alpha below 255: the colour plane sees what is behind it.
        case transparent
        /// Chrome, pearlescent and metal finishes mirror their surroundings.
        case chrome
        case pearlescent
        case metal
        case matteMetallic = "matte_metallic"
        /// Glitter, speckle and other textured materials.
        case material
        /// LDraw's dithered blends (`0x3…`): two colours mixed.
        case dithered
        /// Not in the palette.
        case unknown
    }

    enum Entry: Sendable, Equatable {
        case observable(linear: SIMD3<Float>, oklab: SIMD3<Float>)
        case unobservable(Unobservable)

        var oklab: SIMD3<Float>? {
            if case .observable(_, let oklab) = self { return oklab }
            return nil
        }

        var linear: SIMD3<Float>? {
            if case .observable(let linear, _) = self { return linear }
            return nil
        }
    }

    /// Direct colours (`0x2RRGGBB`) carry RGB in their low 24 bits; dithered
    /// blends start at `0x3000000`.
    static let directColourThreshold = 0x2000000
    static let ditheredColourThreshold = 0x3000000

    private let entries: [Int: Entry]

    init(definitions: [Int: LDrawColorDefinition]) {
        var entries: [Int: Entry] = [:]
        for (code, definition) in definitions {
            entries[code] = Self.entry(from: definition)
        }
        self.entries = entries
    }

    func entry(for code: Int) -> Entry {
        if code >= Self.ditheredColourThreshold { return .unobservable(.dithered) }
        if code >= Self.directColourThreshold {
            return Self.observable(hex: UInt32(code & 0xFFFFFF))
        }
        return entries[code] ?? .unobservable(.unknown)
    }

    private static func entry(from definition: LDrawColorDefinition) -> Entry {
        guard definition.alpha == 255 else { return .unobservable(.transparent) }
        switch definition.finish {
        case .plastic, .rubber: return observable(hex: definition.rgb)
        case .chrome: return .unobservable(.chrome)
        case .pearlescent: return .unobservable(.pearlescent)
        case .metal: return .unobservable(.metal)
        case .matteMetallic: return .unobservable(.matteMetallic)
        case .material: return .unobservable(.material)
        }
    }

    private static func observable(hex: UInt32) -> Entry {
        let linear = ColourMath.linear(hex: hex)
        return .observable(linear: linear, oklab: ColourMath.oklab(linear: linear))
    }
}
