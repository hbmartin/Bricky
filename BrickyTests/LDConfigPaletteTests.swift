import XCTest
@testable import Bricky

final class LDConfigPaletteTests: XCTestCase {
    func testParsesSolidColour() {
        let parsed = LDConfigPalette.parse(
            "0 !COLOUR Blue CODE 1 VALUE #0055BF EDGE #333333"
        )
        XCTAssertEqual(parsed[1]?.name, "Blue")
        XCTAssertEqual(parsed[1]?.rgb, 0x0055BF)
        XCTAssertEqual(parsed[1]?.edgeRGB, 0x333333)
        XCTAssertEqual(parsed[1]?.alpha, 255)
        XCTAssertEqual(parsed[1]?.finish, .plastic)
    }

    func testParsesTransparentColour() {
        let parsed = LDConfigPalette.parse(
            "0 !COLOUR Trans_Red CODE 36 VALUE #C91A09 EDGE #880000 ALPHA 128"
        )
        XCTAssertEqual(parsed[36]?.alpha, 128)
    }

    func testParsesFinishKeywords() {
        let parsed = LDConfigPalette.parse(
            """
            0 !COLOUR Chrome_Gold CODE 334 VALUE #BBA53D EDGE #BBB23D CHROME
            0 !COLOUR Metallic_Silver CODE 80 VALUE #A5A9B4 EDGE #333333 METAL
            0 !COLOUR Rubber_Black CODE 256 VALUE #05131D EDGE #05131D RUBBER
            0 !COLOUR Copper CODE 484 VALUE #965336 EDGE #333333 PEARLESCENT
            0 !COLOUR Matte_Metallic CODE 494 VALUE #D0D0D0 EDGE #6E6E6E MATTE_METALLIC
            """
        )
        XCTAssertEqual(parsed[334]?.finish, .chrome)
        XCTAssertEqual(parsed[80]?.finish, .metal)
        XCTAssertEqual(parsed[256]?.finish, .rubber)
        XCTAssertEqual(parsed[484]?.finish, .pearlescent)
        XCTAssertEqual(parsed[494]?.finish, .matteMetallic)
    }

    func testMaterialSpecUsesBaseValueAndStopsParsing() {
        let parsed = LDConfigPalette.parse(
            "0 !COLOUR Glitter_Trans_Dark_Pink CODE 114 VALUE #DF6695 EDGE #9A2A66 ALPHA 128 MATERIAL GLITTER VALUE #923978 FRACTION 0.17 VFRACTION 0.2 SIZE 1"
        )
        XCTAssertEqual(parsed[114]?.rgb, 0xDF6695)
        XCTAssertEqual(parsed[114]?.alpha, 128)
        XCTAssertEqual(parsed[114]?.finish, .material)
    }

    func testIgnoresMalformedAndUnrelatedLines() {
        let parsed = LDConfigPalette.parse(
            """
            0 // LDraw Colour Definitions
            0 !COLOUR Broken CODE notanumber VALUE #FFFFFF EDGE #000000
            0 !COLOUR MissingValue CODE 999 EDGE #000000
            1 4 0 0 0 1 0 0 0 1 0 0 0 1 3001.dat
            """
        )
        XCTAssertTrue(parsed.isEmpty)
    }

    func testLuminanceIsSkipped() {
        let parsed = LDConfigPalette.parse(
            "0 !COLOUR Glow_In_Dark CODE 21 VALUE #E0FFB0 EDGE #A4C374 ALPHA 250 LUMINANCE 15"
        )
        XCTAssertEqual(parsed[21]?.alpha, 250)
        XCTAssertEqual(parsed[21]?.rgb, 0xE0FFB0)
    }

    @MainActor
    func testInstalledPaletteOverridesFallbackAndDirectColorsBypass() {
        LDrawPalette.install([
            7: LDrawColorDefinition(
                code: 7, name: "Light_Gray", rgb: 0x9BA19D, edgeRGB: 0x333333, alpha: 255, finish: .plastic
            )
        ])
        defer { LDrawPalette.install([:]) }
        XCTAssertEqual(LDrawPalette.definition(7)?.name, "Light_Gray")
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        LDrawPalette.color(7).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(Int(round(red * 255)), 0x9B)
        // Direct colours carry RGB in the low bits and never hit the table.
        XCTAssertNil(LDrawPalette.definition(0x2FF0000))
        LDrawPalette.color(0x2FF0000).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(Int(round(red * 255)), 0xFF)
        XCTAssertEqual(Int(round(green * 255)), 0)
    }
}
