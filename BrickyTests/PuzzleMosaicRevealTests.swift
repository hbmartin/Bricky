import XCTest
@testable import Bricky

final class PuzzleMosaicRevealTests: XCTestCase {
    private func makeProject() -> LegoProject {
        LegoProject(
            name: "Test Build", description: "A test", difficulty: .medium, category: .vehicle,
            estimatedTime: "30 min",
            requiredPieces: [
                RequiredPiece(category: .brick, dimensions: PieceDimensions(studsWide: 2, studsLong: 4, heightUnits: 3),
                              colorPreference: .red, quantity: 4, flexible: false)
            ],
            instructions: [], imageSystemName: "car.fill"
        )
    }

    func testInitialRevealMatchesGridDivFour() {
        let p = BuildPuzzle(project: makeProject(), clues: ["A", "B"], gridSize: 64)
        XCTAssertEqual(p.revealedCellCount, 64 / 4)
        XCTAssertEqual(p.revealedCells.count, 16)
    }

    func testRevealGrowsAndCanRevealMore() {
        var p = BuildPuzzle(project: makeProject(), clues: ["A"], gridSize: 32)
        XCTAssertTrue(p.canRevealMore)
        p.revealedCellCount = p.cellOrder.count
        XCTAssertTrue(p.allCellsRevealed)
        XCTAssertFalse(p.canRevealMore)
    }

    func testPuzzleSettingsRevealPerHint() {
        let s = PuzzleSettings.shared
        s.gridSize = 128
        XCTAssertEqual(s.revealPerHint, 32)
        s.gridSize = 48
        XCTAssertEqual(s.revealPerHint, 12)
    }

    func testGridPresetsIncludeMaxAndStandard() {
        let raws = PuzzleGridPreset.allCases.map(\.rawValue)
        XCTAssertEqual(raws, [32, 48, 64, 96, 128])
    }
}
