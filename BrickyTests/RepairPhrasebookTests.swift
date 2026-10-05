import XCTest
@testable import Bricky

/// The repair wording says which part and which way, and never claims more
/// than Bricky does (CONTRIBUTING: never "automatic", "detected", "found",
/// "locked on").
final class RepairPhrasebookTests: XCTestCase {
    private static let forbidden = ["automatic", "detected", "found", "locked on", "about one stud"]

    private let ref = PlacementRef(placement: 5, placementID: "p5", stepIndex: 2, partReference: "3001.dat", colourCode: 4)
    private let labels = [5: "red Brick 2 x 4"]

    private func everySentence() -> [String] {
        var sentences: [String] = []
        for direction in RelativeDirection.allCases {
            sentences.append(RepairPhrasebook.sentence(for: [.move(ref, by: LatticeOffset(dx: -1))], direction: direction, labels: labels) ?? "")
        }
        let actions: [RepairAction] = [
            .move(ref, by: LatticeOffset(dx: -1)), .add(ref), .rotate(ref, quarterTurns: 1), .rotate(ref, quarterTurns: 2),
            .swapColour(ref, expected: 1), .remove(ref), .reAdd(ref)
        ]
        for action in actions {
            sentences.append(RepairPhrasebook.sentence(for: [action], direction: nil, labels: labels) ?? "")
        }
        return sentences
    }

    func testMovesNameThePartAndTheWay() {
        let sentence = RepairPhrasebook.sentence(for: [.move(ref, by: LatticeOffset(dz: 1))], direction: .towardYou, labels: labels)
        XCTAssertEqual(sentence, "Move the red Brick 2 x 4 one stud toward you.")
        XCTAssertEqual(
            RepairPhrasebook.sentence(for: [.move(ref, by: LatticeOffset(dz: 1))], direction: nil, labels: labels),
            "Move the red Brick 2 x 4 back to where the guide shows it.",
            "no steady direction: no direction claimed"
        )
    }

    func testSeveralPartsAreNamedTogether() {
        let other = PlacementRef(placement: 6, placementID: "p6", stepIndex: 2, partReference: "3003.dat", colourCode: 1)
        let sentence = RepairPhrasebook.sentence(
            for: [.move(ref, by: LatticeOffset(dx: 1)), .move(other, by: LatticeOffset(dx: 1))], direction: .yourRight, labels: labels
        )
        XCTAssertEqual(sentence, "Move the parts from this step one stud to your right.")
    }

    func testEverySentenceIsCompleteAndAvoidsForbiddenWords() {
        for sentence in everySentence() {
            XCTAssertTrue(sentence.hasSuffix("."), sentence)
            XCTAssertTrue(sentence.contains("red Brick 2 x 4"), sentence)
            for word in Self.forbidden {
                XCTAssertFalse(sentence.lowercased().contains(word), "\(word) in: \(sentence)")
            }
        }
    }

    /// The whole catalog, not just what these tests reach.
    func testTheCatalogAvoidsForbiddenWords() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Bricky/Resources/Localizable.xcstrings")
        let text = try String(contentsOf: catalog, encoding: .utf8).lowercased()
        for word in Self.forbidden {
            XCTAssertFalse(text.contains(word), word)
        }
    }

    @MainActor
    func testTheMisplacedLabelNoLongerHidesTheDirection() async {
        let label = String(localized: "This step's parts look shifted")
        XCTAssertFalse(label.contains("about one stud"))
    }
}
