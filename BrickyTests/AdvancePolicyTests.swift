import XCTest
@testable import Bricky

/// Every row of the hands-free advance policy (ADR 0016): what "next" and
/// "next anyway" do for each verdict, on the frontier and off it, attended
/// or not.
final class AdvancePolicyTests: XCTestCase {
    private typealias Source = BuildSessionController.ConfirmationSource

    private let repair = RepairPlan(
        stepID: "s",
        actions: [.move(
            PlacementRef(placement: 0, placementID: "p0", stepIndex: 0, partReference: "3001.dat", colourCode: 4),
            by: LatticeOffset(dx: -1)
        )],
        withheld: [],
        source: .stepVerdict
    )

    private static let verdicts: [StepVerdict?] = [
        nil, .complete, .incomplete, .misplaced(offsetStuds: SIMD2(1, 0)),
        .uncertain(.registrationNotLocked), .uncertain(.poseAmbiguous), .uncertain(.deltaUndetectable),
        .uncertain(.occludedView), .uncertain(.insufficientEvidence),
    ]
    private static let sources: [Source] = [.guide, .arVerified, .photoCheck, .recovery, .voice, .appIntent]

    private func decide(
        _ request: AdvanceRequest, _ verdict: StepVerdict?, source: Source = .voice, repair: RepairPlan? = nil,
        attended: Bool = true, frontier: Bool = true, finished: Bool = false
    ) -> AdvanceDecision {
        AdvancePolicy.decide(
            request: request, source: source, verdict: verdict, repair: repair,
            attended: attended, cursorIsFrontier: frontier, finished: finished
        )
    }

    func testNextAdvancesWhenTheCheckSaysCompleteOrCannotTell() {
        XCTAssertEqual(decide(.next, .complete), .advance)
        XCTAssertEqual(decide(.next, nil), .advance, "no check is not a reason to hold")
        for reason in [UncertainReason.registrationNotLocked, .poseAmbiguous, .deltaUndetectable, .occludedView, .insufficientEvidence] {
            XCTAssertEqual(decide(.next, .uncertain(reason)), .advance, "abstaining is not a reason to hold: \(reason)")
        }
    }

    func testNextHoldsOnANegativeCheckAndCarriesTheRepair() {
        XCTAssertEqual(decide(.next, .incomplete), .holdAndSpeak(nil))
        XCTAssertEqual(decide(.next, .misplaced(offsetStuds: SIMD2(1, 0)), repair: repair), .holdAndSpeak(repair))
    }

    func testNextAnywayAlwaysAdvancesOnTheFrontier() {
        for verdict in Self.verdicts {
            XCTAssertEqual(decide(.nextAnyway, verdict, repair: repair), .advance, "\(String(describing: verdict))")
        }
    }

    func testOffTheFrontierBothRequestsOnlyBrowse() {
        for verdict in Self.verdicts {
            for request in [AdvanceRequest.next, .nextAnyway] {
                XCTAssertEqual(decide(request, verdict, frontier: false), .browseForward)
                XCTAssertEqual(decide(request, verdict, frontier: false, finished: true), .browseForward)
            }
        }
    }

    func testFinishedRefusesOnTheFrontier() {
        XCTAssertEqual(decide(.next, .complete, finished: true), .refuse(.finished))
        XCTAssertEqual(decide(.nextAnyway, .incomplete, finished: true), .refuse(.finished))
    }

    func testHandsFreeNeedsSomeoneThere() {
        for source in [Source.voice, .appIntent] {
            for verdict in Self.verdicts {
                XCTAssertEqual(decide(.nextAnyway, verdict, source: source, attended: false), .refuse(.unattended))
                XCTAssertEqual(decide(.next, verdict, source: source, attended: false, frontier: false), .refuse(.unattended))
            }
        }
    }

    func testOnScreenSourcesAreAttendedByConstruction() {
        for source in [Source.guide, .arVerified, .photoCheck, .recovery] {
            XCTAssertFalse(source.isHandsFree)
            XCTAssertEqual(decide(.next, .complete, source: source, attended: false), .advance)
        }
        XCTAssertTrue(Source.voice.isHandsFree)
        XCTAssertTrue(Source.appIntent.isHandsFree)
    }

    /// Whatever the input, progress only moves on the frontier, attended.
    func testNoInputAdvancesOffTheFrontierOrUnattended() {
        for source in Self.sources {
            for verdict in Self.verdicts {
                for request in [AdvanceRequest.next, .nextAnyway] {
                    for attended in [false, true] {
                        for frontier in [false, true] {
                            for finished in [false, true] {
                                let decision = decide(
                                    request, verdict, source: source, attended: attended, frontier: frontier, finished: finished
                                )
                                guard decision == .advance else { continue }
                                XCTAssertTrue(frontier)
                                XCTAssertFalse(finished)
                                XCTAssertTrue(attended || !source.isHandsFree)
                            }
                        }
                    }
                }
            }
        }
    }
}
