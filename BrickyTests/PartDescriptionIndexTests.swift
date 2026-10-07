import XCTest
@testable import Bricky

final class PartDescriptionIndexTests: XCTestCase {
    private var pack: URL!
    private var source: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parts-\(UUID().uuidString)")
        pack = root.appendingPathComponent("ldraw")
        source = root.appendingPathComponent("Source")
        for directory in [pack.appendingPathComponent("parts"), pack.appendingPathComponent("p"), source!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: pack.deletingLastPathComponent())
    }

    private func write(_ text: String, to url: URL, encoding: String.Encoding = .utf8) throws {
        try XCTUnwrap(text.data(using: encoding)).write(to: url)
    }

    private func index() -> PartDescriptionIndex {
        PartDescriptionIndex(modelSourceRoot: source, partPackRoot: pack)
    }

    func testHeaderLineBecomesTheTitle() async throws {
        try write("0 Brick  2 x  4\n0 Name: 3001.dat\n", to: pack.appendingPathComponent("parts/3001.dat"))
        let description = await index().description(for: "3001.dat")
        XCTAssertEqual(description, PartDescription(reference: "3001.dat", title: "Brick 2 x 4", isFallback: false))
    }

    func testMovedAliasesFollowOneHop() async throws {
        try write("0 ~Moved to 3040b\n", to: pack.appendingPathComponent("parts/3040.dat"))
        try write("0 Slope Brick 45  2 x  1\n", to: pack.appendingPathComponent("parts/3040b.dat"))
        let description = await index().description(for: "3040.dat")
        XCTAssertEqual(description.title, "Slope Brick 45 2 x 1")
        XCTAssertFalse(description.isFallback)
    }

    func testTheModelsOwnPartsWinAndAreSanitized() async throws {
        try write("0 Brick 2 x 4\n", to: pack.appendingPathComponent("parts/custom.dat"))
        let hostile = "0 =Custom\u{0007} part " + String(repeating: "x", count: 200) + "\n"
        try write(hostile, to: source.appendingPathComponent("custom.dat"))
        let description = await index().description(for: "custom.dat")
        XCTAssertTrue(description.title.hasPrefix("Custom part x"))
        XCTAssertFalse(description.title.contains("\u{0007}"))
        XCTAssertEqual(description.title.count, PartDescriptionIndex.maximumTitleLength)
    }

    func testLatin1HeadersDecode() async throws {
        try write("0 Figure Accessory Épée\n", to: pack.appendingPathComponent("parts/epee.dat"), encoding: .isoLatin1)
        let description = await index().description(for: "epee.dat")
        XCTAssertEqual(description.title, "Figure Accessory Épée")
    }

    func testMissingOrHeaderlessFilesFallBackToTheFileName() async throws {
        try write("1 16 0 0 0 1 0 0 0 1 0 0 0 1 stud.dat\n", to: pack.appendingPathComponent("parts/bare.dat"))
        let bare = await index().description(for: "bare.dat")
        let missing = await index().description(for: "nothing.dat")
        XCTAssertEqual(bare, PartDescription(reference: "bare.dat", title: "bare.dat", isFallback: true))
        XCTAssertTrue(missing.isFallback)
    }

    func testAFallbackTitleIsHeldToTheHeaderRules() async throws {
        let hostile = "evil\u{0}\n" + String(repeating: "a", count: 200) + ".dat"
        let fallback = await index().description(for: hostile)
        XCTAssertTrue(fallback.isFallback)
        XCTAssertFalse(fallback.title.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertLessThanOrEqual(fallback.title.count, PartDescriptionIndex.maximumTitleLength)
        XCTAssertEqual(fallback.reference, hostile, "lookups keep the real reference")
    }

    func testColourNames() {
        XCTAssertEqual(PartNaming.colourName(code: 71, definitionName: "Light_Bluish_Grey"), "Light bluish grey")
        XCTAssertEqual(PartNaming.colourName(code: 4, definitionName: "Red"), "Red")
        XCTAssertEqual(PartNaming.colourName(code: 0x2FF0000, definitionName: nil), "Custom colour")
        XCTAssertEqual(PartNaming.colourName(code: 999, definitionName: nil), "Colour 999")
    }
}
