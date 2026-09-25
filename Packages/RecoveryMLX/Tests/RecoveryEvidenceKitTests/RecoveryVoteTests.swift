import XCTest
@testable import RecoveryEvidenceKit

/// The finalist vote shared by the app and the harness. The duplicate-slot
/// cases are the reason it exists: the rank grammar's `uniqueItems` is
/// silently ignored by the pinned xgrammar, so `["B","B","B"]` is legal
/// model output.
final class RecoveryVoteTests: XCTestCase {
    private let finalists = [6, 7, 8]
    private var slots: [String: Int] { ["A": 6, "B": 7, "C": 8] }

    private func view(_ ranking: String...) -> RecoveryVoteView<Int> {
        RecoveryVoteView(ranking: ranking, candidateForSlot: slots)
    }

    func testRepeatedSlotScoresOnceUnderDeduplication() throws {
        let views = [view("B", "B", "B"), view("A", "B", "C")]
        let dedup = try XCTUnwrap(RecoveryVote.aggregate(views: views, finalists: finalists, rule: .bordaDedup))
        XCTAssertEqual(dedup.scores[7], 3 + 2)
        XCTAssertEqual(dedup.scores[6], 3)
        // The legacy rule reproduces what shipped: one degenerate view hands
        // B six points and decides the estimate on its own.
        let legacy = try XCTUnwrap(RecoveryVote.aggregate(views: views, finalists: finalists, rule: .bordaLegacy))
        XCTAssertEqual(legacy.scores[7], 3 + 2 + 1 + 2)
        XCTAssertEqual(legacy.ordered.first, 7)
    }

    func testDeduplicationMovesLaterSlotsUp() throws {
        let views = [view("B", "B", "A"), view("C")]
        let dedup = try XCTUnwrap(RecoveryVote.aggregate(views: views, finalists: finalists, rule: .bordaDedup))
        XCTAssertEqual(dedup.scores[6], 2, "A is second once the repeat is removed")
        let legacy = try XCTUnwrap(RecoveryVote.aggregate(views: views, finalists: finalists, rule: .bordaLegacy))
        XCTAssertEqual(legacy.scores[6], 1)
        XCTAssertEqual(legacy.scores[7], 5)
    }

    func testTiesKeepFinalistOrder() throws {
        // B: 3+3; A: 2+1; C: 1+2 — A and C tie and keep finalist order.
        let outcome = try XCTUnwrap(RecoveryVote.aggregate(
            views: [view("B", "A", "C"), view("B", "C", "A")], finalists: finalists, rule: .bordaDedup
        ))
        XCTAssertEqual(outcome.ordered, [7, 6, 8])
    }

    func testUnmappedSlotsKeepTheirPositions() throws {
        // "D" names no finalist; B still ranks second, not first.
        let outcome = try XCTUnwrap(RecoveryVote.aggregate(
            views: [view("D", "B"), view("A")], finalists: finalists, rule: .bordaDedup
        ))
        XCTAssertEqual(outcome.scores[7], 2)
    }

    func testQuorumNeedsTwoUsableViews() {
        XCTAssertNil(RecoveryVote.aggregate(views: [view("B")], finalists: finalists, rule: .bordaDedup))
        // A view whose every slot is unmapped does not count toward quorum.
        XCTAssertNil(RecoveryVote.aggregate(views: [view("B"), view("E", "F")], finalists: finalists, rule: .bordaDedup))
    }

    func testCertaintyCountsAgreeingLeaders() throws {
        func certainty(_ views: [RecoveryVoteView<Int>]) throws -> RecoveryCertainty {
            try XCTUnwrap(RecoveryVote.aggregate(views: views, finalists: finalists, rule: .bordaDedup)).certainty
        }
        XCTAssertEqual(try certainty([view("B"), view("B"), view("B")]), .high)
        XCTAssertEqual(try certainty([view("B"), view("B"), view("A")]), .medium)
        XCTAssertEqual(try certainty([view("A"), view("B"), view("C")]), .low)
    }

    func testCameraMetadataCarriesIntrinsicsAndResolution() {
        let capture = EvidenceCaptureRecord(
            captureID: UUID(), imageRelativePath: "captures/x.jpg", cameraTransform: [],
            cameraIntrinsics: [1200, 0, 0, 0, 1210, 0, 640, 360, 1], cameraImageResolution: [1920, 1440],
            alignmentID: UUID(), angle: "center", capturedAt: .now
        )
        XCTAssertEqual(
            capture.benchmarkCameraMetadata,
            ["fx": 1200, "fy": 1210, "cx": 640, "cy": 360, "width": 1920, "height": 1440]
        )
    }
}
