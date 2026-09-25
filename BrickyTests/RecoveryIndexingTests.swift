import XCTest
@testable import Bricky

/// The index schedule both recovery estimators and the synthetic tool share.
/// These pin the behavior that moved out of `HierarchicalRecoveryEstimator`,
/// so the extraction (and any later change) cannot shift which steps a pass
/// considers without a test noticing.
final class RecoveryIndexingTests: XCTestCase {
    func testEvenSamplingIncludesBothEndsAndRoundsToNearest() {
        XCTAssertEqual(RecoveryIndexing.evenlySampledIndices(count: 5, range: 0..<9), [0, 2, 4, 6, 8])
        XCTAssertEqual(RecoveryIndexing.evenlySampledIndices(count: 8, range: -1..<20), [-1, 2, 5, 8, 10, 13, 16, 19])
        XCTAssertEqual(RecoveryIndexing.evenlySampledIndices(count: 1, range: 3..<9), [3])
    }

    func testOversamplingDeduplicatesInOrder() {
        // More samples than indices collapses onto every index once.
        XCTAssertEqual(RecoveryIndexing.evenlySampledIndices(count: 8, range: 0..<3), [0, 1, 2])
    }

    func testDegenerateRequestsSampleNothing() {
        XCTAssertEqual(RecoveryIndexing.evenlySampledIndices(count: 0, range: 0..<9), [])
        XCTAssertEqual(RecoveryIndexing.evenlySampledIndices(count: 4, range: 5..<5), [])
    }

    func testSamplingAtMostTheRangeNeverDuplicates() {
        // The synthetic tool relies on this: it samples count <= range.count
        // and used to run a copy without de-duplication.
        for size in 1...40 {
            for count in 1...size {
                let sampled = RecoveryIndexing.evenlySampledIndices(count: count, range: 0..<size)
                XCTAssertEqual(sampled.count, count, "count \(count) of \(size)")
            }
        }
    }

    func testNeighborIntervalSpansTheLeadersSampledNeighbors() {
        let samples = [-1, 2, 5, 8, 10, 13, 16, 19]
        XCTAssertEqual(RecoveryIndexing.neighborInterval(around: 8, samples: samples, lowerBound: -1, upperBound: 20), 5..<11)
        XCTAssertEqual(RecoveryIndexing.neighborInterval(around: -1, samples: samples, lowerBound: -1, upperBound: 20), -1..<3)
        XCTAssertEqual(RecoveryIndexing.neighborInterval(around: 19, samples: samples, lowerBound: -1, upperBound: 20), 16..<20)
    }

    func testNeighborIntervalForAnUnsampledLeaderIsAFixedWindow() {
        XCTAssertEqual(RecoveryIndexing.neighborInterval(around: 7, samples: [0, 3], lowerBound: -1, upperBound: 20), 3..<12)
        XCTAssertEqual(RecoveryIndexing.neighborInterval(around: 1, samples: [5], lowerBound: -1, upperBound: 4), -1..<4)
    }

    func testSlotLettersMapOnlyToCandidatesShown() {
        let candidates = [4, 5, 6]
        XCTAssertEqual(RecoveryIndexing.candidateIndex(forSlot: "A", candidates: candidates), 4)
        XCTAssertEqual(RecoveryIndexing.candidateIndex(forSlot: "c", candidates: candidates), 6)
        XCTAssertNil(RecoveryIndexing.candidateIndex(forSlot: "D", candidates: candidates))
        XCTAssertNil(RecoveryIndexing.candidateIndex(forSlot: nil, candidates: candidates))
        XCTAssertNil(RecoveryIndexing.candidateIndex(forSlot: "", candidates: candidates))
        XCTAssertEqual(RecoveryIndexing.slotLetters, ["A", "B", "C", "D", "E", "F", "G", "H"])
    }
}
