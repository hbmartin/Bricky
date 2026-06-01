import XCTest
@testable import Bricky

final class MosaicCaptionGeneratorTests: XCTestCase {

    private func line(_ part: String, _ color: String, qty: Int) -> MosaicPartLine {
        MosaicPartLine(
            part: part,
            color: color,
            qty: qty,
            ldrawColor: 0,
            bricklinkColor: 0,
            rebrickableColor: 0
        )
    }

    private func partsList(_ lines: [MosaicPartLine]) -> MosaicPartsList {
        MosaicPartsList(
            paletteId: "test",
            parts: lines,
            totalParts: lines.reduce(0) { $0 + $1.qty }
        )
    }

    func testCaptionUsesTopTwoColorsByQuantity() {
        let parts = partsList([
            line("3024", "Bright Green", qty: 100),
            line("3024", "Bright Blue", qty: 200),
            line("3024", "Black", qty: 10)
        ])

        let result = MosaicCaptionGenerator.generate(
            width: 48, height: 48, parts: parts, brickCount: 310
        )

        // Blue (200) leads, Green (100) second.
        XCTAssertEqual(result.caption, "Bright Blue & Bright Green Mosaic")
    }

    func testCaptionTieBreaksAlphabetically() {
        let parts = partsList([
            line("3024", "Red", qty: 50),
            line("3024", "Blue", qty: 50)
        ])

        let result = MosaicCaptionGenerator.generate(
            width: 32, height: 32, parts: parts, brickCount: 100
        )

        // Equal quantities → alphabetical order: Blue before Red.
        XCTAssertEqual(result.caption, "Blue & Red Mosaic")
    }

    func testCaptionWithSingleColor() {
        let parts = partsList([line("3024", "White", qty: 64)])

        let result = MosaicCaptionGenerator.generate(
            width: 8, height: 8, parts: parts, brickCount: 64
        )

        XCTAssertEqual(result.caption, "White Mosaic")
    }

    func testCaptionFallsBackToGridSizeWhenNoColors() {
        let result = MosaicCaptionGenerator.generate(
            width: 16, height: 24, parts: partsList([]), brickCount: 0
        )

        XCTAssertEqual(result.caption, "16×24 LEGO Mosaic")
    }

    func testDescriptionMentionsGridBrickAndPalette() {
        let parts = partsList([
            line("3024", "Bright Blue", qty: 300),
            line("3024", "Bright Green", qty: 200),
            line("3024", "Black", qty: 100)
        ])

        let result = MosaicCaptionGenerator.generate(
            width: 48, height: 48, parts: parts, brickCount: 600
        )

        XCTAssertTrue(result.description.contains("48 × 48 stud"))
        XCTAssertTrue(result.description.contains("600 bricks"))
        XCTAssertTrue(
            result.description.contains("Bright Blue, Bright Green, and Black"),
            result.description
        )
        XCTAssertTrue(
            result.description.contains("3 unique part-and-color combinations"),
            result.description
        )
    }

    func testDescriptionUsesSingularCombination() {
        let parts = partsList([line("3024", "Red", qty: 4)])

        let result = MosaicCaptionGenerator.generate(
            width: 2, height: 2, parts: parts, brickCount: 4
        )

        XCTAssertTrue(
            result.description.contains("1 unique part-and-color combination."),
            result.description
        )
        XCTAssertFalse(result.description.contains("combinations"))
    }

    func testGenerationIsDeterministic() {
        let parts = partsList([
            line("3024", "Bright Blue", qty: 120),
            line("3024", "Bright Green", qty: 120)
        ])

        let first = MosaicCaptionGenerator.generate(
            width: 24, height: 24, parts: parts, brickCount: 240
        )
        let second = MosaicCaptionGenerator.generate(
            width: 24, height: 24, parts: parts, brickCount: 240
        )

        XCTAssertEqual(first, second)
    }
}
