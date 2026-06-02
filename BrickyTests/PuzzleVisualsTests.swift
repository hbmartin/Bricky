import XCTest
@testable import Bricky

/// Tests for the puzzle game enhancements: progressive visual reveal,
/// win-streak bonus scoring, and the color-palette hint.
final class PuzzleVisualsTests: XCTestCase {

    // MARK: - Visual reveal fraction

    func testRevealFractionStartsAtZero() {
        let puzzle = makePuzzle(clues: ["a", "b", "c", "d", "e"])
        // A fresh puzzle reveals exactly one clue.
        XCTAssertEqual(puzzle.revealFraction, 0.0, accuracy: 0.0001,
                       "First clue should be the most-hidden state")
    }

    func testRevealFractionReachesOneAtLastClue() {
        var puzzle = makePuzzle(clues: ["a", "b", "c", "d", "e"])
        puzzle.revealedClues = puzzle.clues.count
        XCTAssertEqual(puzzle.revealFraction, 1.0, accuracy: 0.0001,
                       "All clues revealed should be fully visible")
    }

    func testRevealFractionMidway() {
        var puzzle = makePuzzle(clues: ["a", "b", "c", "d", "e"])
        puzzle.revealedClues = 3 // (3-1)/(5-1) = 0.5
        XCTAssertEqual(puzzle.revealFraction, 0.5, accuracy: 0.0001)
    }

    func testRevealFractionSingleClueIsFullyRevealed() {
        let puzzle = makePuzzle(clues: ["only"])
        XCTAssertEqual(puzzle.revealFraction, 1.0, accuracy: 0.0001,
                       "A one-clue puzzle can't be progressively hidden")
    }

    // MARK: - Streak bonus

    func testNoStreakBonusForFirstSolve() {
        XCTAssertEqual(PuzzleEngine.shared.streakBonus(for: 1), 0)
        XCTAssertEqual(PuzzleEngine.shared.streakBonus(for: 0), 0)
    }

    func testStreakBonusScalesWithStreak() {
        XCTAssertEqual(PuzzleEngine.shared.streakBonus(for: 2), 10)
        XCTAssertEqual(PuzzleEngine.shared.streakBonus(for: 3), 20)
        XCTAssertEqual(PuzzleEngine.shared.streakBonus(for: 4), 30)
    }

    func testStreakBonusIsCapped() {
        XCTAssertEqual(PuzzleEngine.shared.streakBonus(for: 6), 50)
        XCTAssertEqual(PuzzleEngine.shared.streakBonus(for: 100), 50,
                       "Streak bonus must not grow unbounded")
    }

    // MARK: - Color palette hint

    func testPaletteColorsDerivedFromRequiredPieces() {
        let project = makeProject(requiredPieces: [
            RequiredPiece(category: .brick, dimensions: dims(2, 4), colorPreference: .red, quantity: 5, flexible: false),
            RequiredPiece(category: .plate, dimensions: dims(2, 2), colorPreference: .blue, quantity: 2, flexible: false)
        ])
        let colors = PuzzleEngine.shared.paletteColors(for: project)
        XCTAssertEqual(colors, [.red, .blue],
                       "Most-used color should come first")
    }

    func testPaletteColorsIgnoresFlexibleAndColorlessPieces() {
        let project = makeProject(requiredPieces: [
            RequiredPiece(category: .brick, dimensions: dims(2, 4), colorPreference: .red, quantity: 1, flexible: true),
            RequiredPiece(category: .plate, dimensions: dims(2, 2), colorPreference: nil, quantity: 3, flexible: false),
            RequiredPiece(category: .brick, dimensions: dims(1, 1), colorPreference: .green, quantity: 2, flexible: false)
        ])
        let colors = PuzzleEngine.shared.paletteColors(for: project)
        XCTAssertEqual(colors, [.green],
                       "Flexible and nil-color pieces should not contribute swatches")
    }

    func testPaletteColorsRespectsLimit() {
        let project = makeProject(requiredPieces: [
            RequiredPiece(category: .brick, dimensions: dims(1, 1), colorPreference: .red, quantity: 6, flexible: false),
            RequiredPiece(category: .brick, dimensions: dims(1, 1), colorPreference: .blue, quantity: 5, flexible: false),
            RequiredPiece(category: .brick, dimensions: dims(1, 1), colorPreference: .green, quantity: 4, flexible: false),
            RequiredPiece(category: .brick, dimensions: dims(1, 1), colorPreference: .yellow, quantity: 3, flexible: false),
            RequiredPiece(category: .brick, dimensions: dims(1, 1), colorPreference: .orange, quantity: 2, flexible: false),
            RequiredPiece(category: .brick, dimensions: dims(1, 1), colorPreference: .purple, quantity: 1, flexible: false)
        ])
        let colors = PuzzleEngine.shared.paletteColors(for: project, limit: 3)
        XCTAssertEqual(colors.count, 3)
        XCTAssertEqual(colors, [.red, .blue, .green],
                       "Limit should keep the most-used colors")
    }

    func testPaletteColorsEmptyForFlexibleOnlyProject() {
        let project = makeProject(requiredPieces: [
            RequiredPiece(category: .brick, dimensions: dims(2, 4), colorPreference: .red, quantity: 4, flexible: true)
        ])
        XCTAssertTrue(PuzzleEngine.shared.paletteColors(for: project).isEmpty)
    }

    // MARK: - Pro puzzle-pack gating

    func testFreeAndProPackLimitsAreDistinct() {
        XCTAssertEqual(SubscriptionManager.freePuzzleLimit, 10)
        XCTAssertEqual(SubscriptionManager.proPuzzleLimit, 50)
        XCTAssertLessThan(SubscriptionManager.freePuzzleLimit,
                          SubscriptionManager.proPuzzleLimit,
                          "Free pack must be smaller than the Pro pack")
    }

    func testPuzzlePoolHonorsPackSize() {
        let total = BuildSuggestionEngine.shared.allProjects.count
        let freeLimit = SubscriptionManager.freePuzzleLimit
        guard total >= freeLimit else {
            XCTFail("Catalog (\(total)) must have at least \(freeLimit) projects for the free pack")
            return
        }
        let freePool = PuzzleEngine.shared.puzzlePool(limit: freeLimit)
        XCTAssertEqual(freePool.count, freeLimit,
                       "Free pack should expose exactly the free limit")

        let proLimit = SubscriptionManager.proPuzzleLimit
        let proPool = PuzzleEngine.shared.puzzlePool(limit: proLimit)
        XCTAssertEqual(proPool.count, min(proLimit, total),
                       "Pro pack should expose up to the Pro limit")
    }

    func testFreePackIsStrictSubsetOfProPack() {
        let freeNames = PuzzleEngine.shared
            .puzzlePool(limit: SubscriptionManager.freePuzzleLimit)
            .map(\.name)
        let proNames = Set(PuzzleEngine.shared
            .puzzlePool(limit: SubscriptionManager.proPuzzleLimit)
            .map(\.name))
        for name in freeNames {
            XCTAssertTrue(proNames.contains(name),
                          "Every free puzzle must also exist in the Pro pack")
        }
    }

    func testPuzzlePoolIsDeterministic() {
        let first = PuzzleEngine.shared.puzzlePool(limit: 10).map(\.name)
        let second = PuzzleEngine.shared.puzzlePool(limit: 10).map(\.name)
        XCTAssertEqual(first, second,
                       "Pack ordering must be stable across calls")
        XCTAssertEqual(first, first.sorted(),
                       "Pack should be ordered by name")
    }

    func testNilPoolReturnsFullCatalog() {
        let pool = PuzzleEngine.shared.puzzlePool(limit: nil)
        XCTAssertEqual(pool.count, BuildSuggestionEngine.shared.allProjects.count)
    }

    func testGeneratePuzzleStaysWithinPack() {
        let packNames = Set(PuzzleEngine.shared.puzzlePool(limit: 10).map(\.name))
        for _ in 0..<25 {
            PuzzleEngine.shared.generatePuzzle(poolLimit: 10)
            guard let puzzle = PuzzleEngine.shared.currentPuzzle else {
                XCTFail("generatePuzzle should produce a puzzle")
                return
            }
            XCTAssertTrue(packNames.contains(puzzle.project.name),
                          "A gated puzzle must come from the requested pack")
        }
    }

    // MARK: - Featured pieces preview

    func testFeaturedPiecesOrderedByQuantity() {
        let project = makeProject(requiredPieces: [
            RequiredPiece(category: .plate, dimensions: dims(2, 2), colorPreference: .blue, quantity: 2, flexible: false),
            RequiredPiece(category: .brick, dimensions: dims(2, 4), colorPreference: .red, quantity: 8, flexible: false),
            RequiredPiece(category: .tile, dimensions: dims(1, 2), colorPreference: .green, quantity: 5, flexible: false)
        ])
        let pieces = PuzzleEngine.shared.featuredPieces(for: project)
        XCTAssertEqual(pieces.map(\.category), [.brick, .tile, .plate],
                       "Most-used pieces should come first")
    }

    func testFeaturedPiecesDeduplicatesByLook() {
        let project = makeProject(requiredPieces: [
            RequiredPiece(category: .brick, dimensions: dims(2, 4), colorPreference: .red, quantity: 4, flexible: false),
            RequiredPiece(category: .brick, dimensions: dims(2, 4), colorPreference: .red, quantity: 2, flexible: false),
            RequiredPiece(category: .plate, dimensions: dims(2, 2), colorPreference: .blue, quantity: 1, flexible: false)
        ])
        let pieces = PuzzleEngine.shared.featuredPieces(for: project)
        XCTAssertEqual(pieces.count, 2,
                       "Identical-looking pieces should collapse to one thumbnail")
    }

    func testFeaturedPiecesRespectsLimit() {
        let many = (0..<10).map { i in
            RequiredPiece(category: .brick, dimensions: dims(1, i + 1), colorPreference: .red, quantity: 10 - i, flexible: false)
        }
        let project = makeProject(requiredPieces: many)
        XCTAssertEqual(PuzzleEngine.shared.featuredPieces(for: project, limit: 4).count, 4)
    }

    // MARK: - Shareable result card

    func testShareTextReportsCluesUsed() {
        var puzzle = makePuzzle(clues: ["a", "b", "c", "d", "e"])
        puzzle.revealedClues = 2
        let text = PuzzleEngine.shared.shareText(for: puzzle)
        XCTAssertTrue(text.contains("2/5 clues"),
                      "Share text should report clues used out of total")
        XCTAssertTrue(text.contains("🟩🟩⬜️⬜️⬜️"),
                      "Grid should fill one square per revealed clue")
    }

    func testShareTextSingleClueGrammar() {
        let puzzle = makePuzzle(clues: ["only"])
        let text = PuzzleEngine.shared.shareText(for: puzzle)
        XCTAssertTrue(text.contains("1/1 clue"),
                      "Singular clue count should read '1 clue'")
        XCTAssertFalse(text.contains("1 clues"))
    }

    // MARK: - Helpers

    private func dims(_ w: Int, _ l: Int) -> PieceDimensions {
        PieceDimensions(studsWide: w, studsLong: l, heightUnits: 3)
    }

    private func makeProject(requiredPieces: [RequiredPiece]) -> LegoProject {
        LegoProject(
            name: "Test Build",
            description: "Test",
            difficulty: .medium,
            category: .vehicle,
            estimatedTime: "10 min",
            requiredPieces: requiredPieces,
            instructions: [],
            imageSystemName: "car.fill"
        )
    }

    private func makePuzzle(clues: [String]) -> BuildPuzzle {
        BuildPuzzle(project: makeProject(requiredPieces: []), clues: clues)
    }
}
