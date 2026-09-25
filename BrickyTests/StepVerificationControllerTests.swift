import XCTest
import simd
@testable import Bricky

/// Verification must run beside tracking, never inside it. `submit` hands a
/// frame off and returns; a single worker judges only the newest frame; and
/// a step change discards whatever was in flight.
@MainActor
final class StepVerificationControllerTests: XCTestCase {
    /// Records every ingested timestamp and holds the first ingest open
    /// until released, so tests can submit while the verifier is busy.
    private actor GatedVerifier: StepVerifying {
        private(set) var ingested: [TimeInterval] = []
        private(set) var begins = 0
        private var holdNext = true
        private var gate: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        private var hasArrived = false

        func begin(stepID: String, completedSnapshot: InstructionGeometrySnapshot, deltaSnapshot: InstructionGeometrySnapshot) {
            begins += 1
        }

        func resetEvidence() {}

        func ingest(frame: RegistrationFrameInput, registration: ModelRegistration) async throws -> StepVerification {
            ingested.append(frame.timestamp)
            if holdNext {
                holdNext = false
                hasArrived = true
                arrival?.resume()
                arrival = nil
                await withCheckedContinuation { gate = $0 }
            }
            return StepVerification(
                stepID: "step",
                verdict: .complete,
                detectability: .strong,
                deltaPixels: 100,
                framesUsed: 1,
                completeFraction: 1,
                incompleteFraction: 0,
                registrationQuality: registration.quality,
                timestamp: frame.timestamp
            )
        }

        /// Returns once the held ingest has started.
        func waitForHeldIngest() async {
            if hasArrived { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func release() {
            gate?.resume()
            gate = nil
        }
    }

    private let emptySnapshot = InstructionGeometrySnapshot(buffers: [], bounds: nil)

    private func frame(at timestamp: TimeInterval) -> RegistrationFrameInput {
        RegistrationFrameInput(
            depth: [], confidence: [], rawDepth: nil, rawConfidence: nil, width: 0, height: 0,
            depthIntrinsics: matrix_identity_float3x3, worldFromCamera: matrix_identity_float4x4,
            timestamp: timestamp
        )
    }

    private let registration = ModelRegistration(
        alignmentID: UUID(),
        worldFromModel: matrix_identity_float4x4,
        state: .locked,
        quality: RegistrationQuality(rmsResidual: 0.002, inlierFraction: 0.8, latticeMargin: 2),
        fittedStepIndex: 0,
        timestamp: 0
    )

    private func makeController(_ verifier: GatedVerifier) async -> StepVerificationController {
        let controller = StepVerificationController(makeVerifier: { verifier })
        await controller.begin(stepID: "step", completedSnapshot: emptySnapshot, deltaSnapshot: emptySnapshot)
        return controller
    }

    /// Lets the worker run until the verifier has seen `count` frames.
    private func waitForIngests(_ verifier: GatedVerifier, count: Int) async {
        for _ in 0..<1_000 where await verifier.ingested.count < count {
            await Task.yield()
        }
    }

    func testOnlyTheNewestWaitingFrameIsJudged() async {
        let verifier = GatedVerifier()
        let controller = await makeController(verifier)

        controller.submit(frame: frame(at: 1.0), registration: registration)
        await verifier.waitForHeldIngest()
        // Three frames arrive while the verifier is busy; only the newest
        // may be judged next — the others were superseded, not queued.
        controller.submit(frame: frame(at: 1.5), registration: registration)
        controller.submit(frame: frame(at: 2.0), registration: registration)
        controller.submit(frame: frame(at: 2.5), registration: registration)
        await verifier.release()
        await waitForIngests(verifier, count: 2)

        let ingested = await verifier.ingested
        XCTAssertEqual(ingested, [1.0, 2.5])
        XCTAssertEqual(controller.verification?.timestamp, 2.5)
    }

    func testSubmissionsWithinTheThrottleIntervalAreDropped() async {
        let verifier = GatedVerifier()
        await verifier.release()
        let controller = await makeController(verifier)
        controller.submit(frame: frame(at: 1.0), registration: registration)
        controller.submit(frame: frame(at: 1.1), registration: registration)
        await waitForIngests(verifier, count: 1)
        for _ in 0..<50 { await Task.yield() }
        let ingested = await verifier.ingested
        XCTAssertEqual(ingested, [1.0])
    }

    func testAStepChangeDiscardsTheFrameInFlight() async {
        let verifier = GatedVerifier()
        let controller = await makeController(verifier)

        controller.submit(frame: frame(at: 1.0), registration: registration)
        await verifier.waitForHeldIngest()
        await controller.begin(stepID: "next", completedSnapshot: emptySnapshot, deltaSnapshot: emptySnapshot)
        await verifier.release()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertNil(controller.verification, "a verdict for the previous step must not publish into the next")
        let begins = await verifier.begins
        XCTAssertEqual(begins, 2)
    }

    func testStopRefusesFurtherFrames() async {
        let verifier = GatedVerifier()
        await verifier.release()
        let controller = await makeController(verifier)
        controller.stop()
        controller.submit(frame: frame(at: 5.0), registration: registration)
        for _ in 0..<50 { await Task.yield() }
        let ingested = await verifier.ingested
        XCTAssertTrue(ingested.isEmpty)
        XCTAssertNil(controller.verification)
    }
}
