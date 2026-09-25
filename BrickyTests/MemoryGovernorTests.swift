import XCTest
@testable import Bricky

/// Admission reads the process budget, not the momentary available bytes a
/// loaded model has already consumed, and holds admission through small
/// dips (ADR 0003 amendment).
final class MemoryGovernorTests: XCTestCase {
    private let gib: UInt64 = 1_024 * 1_024 * 1_024
    private let mib: UInt64 = 1_024 * 1_024

    private var governor: MemoryGovernor {
        MemoryGovernor(floorBytes: 5 * gib, hysteresisBytes: 256 * mib)
    }

    func testTheBudgetDoesNotMoveWhenTheModelLoads() {
        let beforeLoad = MemoryBudget(availableBytes: 6 * gib, footprintBytes: 1 * gib)
        let afterLoad = MemoryBudget(availableBytes: 3 * gib, footprintBytes: 4 * gib)
        XCTAssertEqual(beforeLoad.totalBytes, afterLoad.totalBytes)
    }

    func testALoadedModelIsNotRefusedForItsOwnWeights() {
        // 3 GiB resident: available alone (3 GiB) is under the floor, but the
        // model's headroom is everything but the other 1 GiB.
        let loaded = MemoryBudget(availableBytes: 3 * gib, footprintBytes: 4 * gib)
        XCTAssertEqual(governor.headroom(loaded, modelResidentBytes: 3 * gib), 6 * gib)
        XCTAssertEqual(governor.evaluate(loaded, modelResidentBytes: 3 * gib, currentlyAdmitted: false), .admit)
        XCTAssertEqual(
            governor.evaluate(loaded, modelResidentBytes: 0, currentlyAdmitted: false),
            .refuse(shortfallBytes: 2 * gib),
            "without the resident credit the same reading refuses"
        )
    }

    func testAdmissionHoldsThroughADipSmallerThanTheMargin() {
        let dip = MemoryBudget(availableBytes: 5 * gib - 100 * mib, footprintBytes: 1 * gib)
        XCTAssertEqual(governor.evaluate(dip, modelResidentBytes: 0, currentlyAdmitted: true), .admit)
        XCTAssertEqual(
            governor.evaluate(dip, modelResidentBytes: 0, currentlyAdmitted: false),
            .refuse(shortfallBytes: 100 * mib),
            "a model not yet admitted needs the full floor"
        )
        let fall = MemoryBudget(availableBytes: 5 * gib - 300 * mib, footprintBytes: 1 * gib)
        XCTAssertEqual(governor.evaluate(fall, modelResidentBytes: 0, currentlyAdmitted: true), .refuse(shortfallBytes: 44 * mib))
    }

    func testResidentBytesBeyondTheFootprintAreClamped() {
        let budget = MemoryBudget(availableBytes: 2 * gib, footprintBytes: 1 * gib)
        XCTAssertEqual(governor.headroom(budget, modelResidentBytes: 5 * gib), 3 * gib)
    }
}
