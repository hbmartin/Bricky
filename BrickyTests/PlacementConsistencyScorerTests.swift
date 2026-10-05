import XCTest
@testable import Bricky

/// The tie-break ranks steps by which one the observed placements agree
/// with; one forgotten part is explained, a contradiction is not.
final class PlacementConsistencyScorerTests: XCTestCase {
    private typealias Scorer = PlacementConsistencyScorer

    /// Steps 0…4 build placements 0…1, 2, 3…4, 5, 6: cumulative counts.
    private let built = [2, 3, 5, 6, 7]

    private func ranked(_ observations: [Int: Scorer.Observation], blockers: [Int: [Int]] = [:]) -> [Scorer.Ranking] {
        Scorer.rank(
            candidates: built.indices.map { ($0, built[$0]) },
            observations: observations,
            blockers: { blockers[$0] ?? [] }
        )
    }

    private func winner(_ rankings: [Scorer.Ranking]) -> Int? {
        guard let best = rankings.first else { return nil }
        if rankings.count > 1, !Scorer.isStrictlyBetter(best, rankings[1]) { return nil }
        return best.candidate
    }

    func testMinusPartCurrentResolvesToItsStep() {
        // Step 2 adds 3 and 4; 3 is in place, 4 is missing; step 3's 5 too.
        let observations: [Int: Scorer.Observation] = [0: .supported, 1: .supported, 2: .supported, 3: .supported, 4: .absent, 5: .absent, 6: .absent]
        XCTAssertEqual(winner(ranked(observations)), 2)
    }

    func testAForgottenEarlierPartIsExplained() {
        // Everything through step 3 is in place except 2 (step 1), which
        // nothing rests on.
        let observations: [Int: Scorer.Observation] = [0: .supported, 1: .supported, 2: .absent, 3: .supported, 4: .supported, 5: .supported, 6: .absent]
        let rankings = ranked(observations)
        XCTAssertEqual(winner(rankings), 3)
        XCTAssertEqual(rankings.first?.exceptions, 1)
    }

    func testAnAbsenceUnderASupportedPartAbstains() {
        let observations: [Int: Scorer.Observation] = [0: .supported, 1: .supported, 2: .absent, 3: .supported, 4: .supported, 5: .absent, 6: .absent]
        XCTAssertTrue(Scorer.isImplausible(observations: observations, blockers: { $0 == 2 ? [3] : [] }))
        XCTAssertFalse(Scorer.isImplausible(observations: observations, blockers: { _ in [] }))
    }

    func testEqualCandidatesAbstain() {
        let observations: [Int: Scorer.Observation] = [0: .neutral, 1: .neutral, 2: .neutral, 3: .neutral, 4: .neutral, 5: .neutral, 6: .neutral]
        XCTAssertNil(winner(ranked(observations)))
    }

    func testTwoAbsencesAreNotBothExplained() {
        // 2 and 3 missing: only one may be an exception for any candidate.
        let observations: [Int: Scorer.Observation] = [0: .supported, 1: .supported, 2: .absent, 3: .absent, 4: .supported, 5: .supported, 6: .absent]
        XCTAssertTrue(ranked(observations).allSatisfy { $0.exceptions <= 1 })
    }

    func testContestedPlacementsSpanTheWindow() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        var lines: [String] = ["0 Steps"]
        for step in 0..<6 {
            lines.append("1 4 \(step * 40) 0 0 1 0 0 0 1 0 0 0 1 3001.dat")
            lines.append("0 STEP")
        }
        let file = InstructionSourceFile(relativePath: "main.ldr", data: Data(lines.joined(separator: "\n").utf8))
        let plan = try InstructionPlanBuilder().build(
            document: try LDrawInstructionParser().parse(files: [file], rootRelativePath: "main.ldr"),
            title: "Steps", sourceFilename: "main.ldr", sourceSHA256: "t"
        )
        XCTAssertEqual(Scorer.contestedPlacements(plan: plan, candidates: 1...4, leader: 3, limit: 48), [1, 2, 3, 4])
        XCTAssertEqual(Scorer.contestedPlacements(plan: plan, candidates: 1...4, leader: 3, limit: 2), [3, 4], "nearest the leader's frontier first")
    }
}
