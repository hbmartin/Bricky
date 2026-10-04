import XCTest
@testable import RecoveryEvidenceKit

final class ProbeScoringTests: XCTestCase {
    func testTokenMassGoesToTheOptionItBegins() {
        let grouped = ProbeScoring.group(
            [("in", 0.5), ("unc", 0.3), ("complete", 0.1), ("com", 0.05), ("\"", 0.05)],
            options: ["complete", "incomplete", "uncertain"]
        )
        // The quote begins no option and is renormalized away.
        XCTAssertEqual(grouped["incomplete"]!, 0.5 / 0.95, accuracy: 1e-12)
        XCTAssertEqual(grouped["uncertain"]!, 0.3 / 0.95, accuracy: 1e-12)
        XCTAssertEqual(grouped["complete"]!, 0.15 / 0.95, accuracy: 1e-12)
    }

    func testAmbiguousPrefixesSplitTheirMass() {
        let grouped = ProbeScoring.group([("i", 1.0)], options: ["incomplete", "insufficient"])
        XCTAssertEqual(grouped["incomplete"], 0.5)
        XCTAssertEqual(grouped["insufficient"], 0.5)
    }

    func testRankedOrderIsByProbabilityThenName() {
        XCTAssertEqual(ProbeReadout(pInsufficient: 0.1, options: ["A": 0.2, "B": 0.6, "C": 0.2]).ranked, ["B", "A", "C"])
    }

    func testVariantIDNamesProbeScoring() {
        XCTAssertEqual(RecoveryInferenceVariant(vote: .logprob, scoring: .probe).id, "vote=logprob,scoring=probe")
    }
}

final class LogProbabilityVoteTests: XCTestCase {
    private let finalists = [6, 7, 8]
    private let slots = ["A": 6, "B": 7, "C": 8]

    private func view(_ probabilities: [String: Double]) -> RecoveryVoteView<Int> {
        RecoveryVoteView(ranking: probabilities.sorted { $0.value > $1.value }.map(\.key), candidateForSlot: slots, slotProbabilities: probabilities)
    }

    func testConfidenceOutweighsOrder() throws {
        // Borda sees two views preferring A. Log pooling sees that the view
        // preferring B was near certain and the A views were not.
        let views = [
            view(["A": 0.40, "B": 0.35, "C": 0.25]),
            view(["A": 0.40, "B": 0.35, "C": 0.25]),
            view(["A": 0.01, "B": 0.98, "C": 0.01])
        ]
        let pooled = try XCTUnwrap(RecoveryVote.aggregate(views: views, finalists: finalists, rule: .logprob))
        XCTAssertEqual(pooled.ordered.first, 7)
        let borda = try XCTUnwrap(RecoveryVote.aggregate(views: views, finalists: finalists, rule: .bordaDedup))
        XCTAssertEqual(borda.ordered.first, 6)
    }

    func testCertaintyComesFromThePooledPosterior() throws {
        let sure = try XCTUnwrap(RecoveryVote.aggregate(
            views: [view(["A": 0.9, "B": 0.05, "C": 0.05]), view(["A": 0.9, "B": 0.05, "C": 0.05])],
            finalists: finalists, rule: .logprob
        ))
        XCTAssertEqual(sure.certainty, .high)
        let split = try XCTUnwrap(RecoveryVote.aggregate(
            views: [view(["A": 0.34, "B": 0.33, "C": 0.33]), view(["A": 0.33, "B": 0.34, "C": 0.33])],
            finalists: finalists, rule: .logprob
        ))
        XCTAssertEqual(split.certainty, .low)
    }

    func testViewsWithoutProbabilitiesDoNotVote() {
        let unscored = RecoveryVoteView(ranking: ["A"], candidateForSlot: slots)
        XCTAssertNil(RecoveryVote.aggregate(views: [unscored, view(["A": 1])], finalists: finalists, rule: .logprob))
    }
}
