import Foundation

/// One `LDConfig.ldr` colour definition. `alpha` is the authored 0–255 value
/// (255 opaque); `finish` collapses LDraw's material keywords to the
/// distinctions the renderer actually makes.
struct LDrawColorDefinition: Sendable, Equatable {
    enum Finish: Sendable, Equatable {
        case plastic
        case chrome
        case pearlescent
        case rubber
        case matteMetallic
        case metal
        case material
    }

    let code: Int
    let name: String
    let rgb: UInt32
    let edgeRGB: UInt32?
    let alpha: UInt8
    let finish: Finish
}

/// Parses the installed part pack's `LDConfig.ldr` into the palette table the
/// renderers consult. The parser is deliberately forgiving: a malformed line
/// yields no definition rather than failing the load, because the hardcoded
/// fallback palette in `LDrawPalette` always exists underneath.
enum LDConfigPalette {
    static let fileName = "LDConfig.ldr"

    static func load(libraryURL: URL) throws -> [Int: LDrawColorDefinition] {
        let text = try String(
            contentsOf: libraryURL.appendingPathComponent(fileName),
            encoding: .utf8
        )
        return parse(text)
    }

    static func parse(_ text: String) -> [Int: LDrawColorDefinition] {
        var result: [Int: LDrawColorDefinition] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let definition = parseLine(line) else { continue }
            result[definition.code] = definition
        }
        return result
    }

    /// `0 !COLOUR <name> CODE <n> VALUE #RRGGBB EDGE <#RRGGBB|n>
    ///  [ALPHA <n>] [LUMINANCE <n>] [CHROME|PEARLESCENT|RUBBER|MATTE_METALLIC|
    ///  METAL|MATERIAL <spec…>]`
    private static func parseLine(_ line: Substring) -> LDrawColorDefinition? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 8, tokens[0] == "0", tokens[1] == "!COLOUR" else { return nil }
        let name = String(tokens[2])
        var code: Int?
        var rgb: UInt32?
        var edgeRGB: UInt32?
        var alpha: UInt8 = 255
        var finish = LDrawColorDefinition.Finish.plastic

        var index = 3
        while index < tokens.count {
            let keyword = tokens[index]
            switch keyword {
            case "CODE":
                guard index + 1 < tokens.count, let value = Int(tokens[index + 1]) else { return nil }
                code = value
                index += 2
            case "VALUE":
                guard index + 1 < tokens.count, let value = hexColor(tokens[index + 1]) else { return nil }
                rgb = value
                index += 2
            case "EDGE":
                // The edge may be a hex literal or a palette-code reference;
                // only literals are stored, code references fall back to the
                // renderer's default edge treatment.
                guard index + 1 < tokens.count else { return nil }
                edgeRGB = hexColor(tokens[index + 1])
                index += 2
            case "ALPHA":
                guard index + 1 < tokens.count, let value = UInt8(tokens[index + 1]) else { return nil }
                alpha = value
                index += 2
            case "LUMINANCE":
                index += 2
            case "CHROME":
                finish = .chrome
                index += 1
            case "PEARLESCENT":
                finish = .pearlescent
                index += 1
            case "RUBBER":
                finish = .rubber
                index += 1
            case "MATTE_METALLIC":
                finish = .matteMetallic
                index += 1
            case "METAL":
                finish = .metal
                index += 1
            case "MATERIAL":
                // The remainder of the line is a nested material spec
                // (glitter/speckle); the base VALUE/ALPHA already parsed is
                // what the solid renderer uses.
                finish = .material
                index = tokens.count
            default:
                index += 1
            }
        }

        guard let code, let rgb else { return nil }
        return LDrawColorDefinition(
            code: code,
            name: name,
            rgb: rgb,
            edgeRGB: edgeRGB,
            alpha: alpha,
            finish: finish
        )
    }

    private static func hexColor(_ token: Substring) -> UInt32? {
        var hex = token
        if hex.hasPrefix("#") {
            hex = hex.dropFirst()
        } else if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = hex.dropFirst(2)
        } else {
            return nil
        }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return value
    }
}
