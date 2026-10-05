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
    private actor GatedVerifier: StepJudging {
        private(set) var ingested: [TimeInterval] = []
        private(set) var begins = 0
        private var holdNext = true
        private var gate: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        private var hasArrived = false

        func begin(stepID: String, geometry: StepGeometry) {
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

    /// Returns the scripted verdicts in order, one per ingest, then repeats
    /// the last.
    private actor ScriptedVerifier: StepJudging {
        private var verdicts: [StepVerdict]
        init(_ verdicts: [StepVerdict]) { self.verdicts = verdicts }
        func begin(stepID: String, geometry: StepGeometry) {}
        func resetEvidence() {}
        func ingest(frame: RegistrationFrameInput, registration: ModelRegistration) async throws -> StepVerification {
            let verdict = verdicts.count > 1 ? verdicts.removeFirst() : verdicts[0]
            return StepVerification(
                stepID: "step", verdict: verdict, detectability: .strong, deltaPixels: 100, framesUsed: 1,
                completeFraction: 0, incompleteFraction: 0, registrationQuality: registration.quality,
                timestamp: frame.timestamp
            )
        }
    }

    private actor WindowCollector: VerificationWindowSink {
        private(set) var windows: [VerificationWindowCapture] = []
        func record(_ window: VerificationWindowCapture) async { windows.append(window) }
    }

    /// A shadow that disagrees with everything, records what it saw, and
    /// can be made to fail.
    private actor ShadowFake: ShadowStepJudging {
        private(set) var ingested: [TimeInterval] = []
        private(set) var begins = 0
        private var failing = false
        func begin(stepID: String, geometry: StepGeometry) { begins += 1 }
        func resetEvidence() {}
        func fail() { failing = true }
        func ingest(frame: RegistrationFrameInput, registration: ModelRegistration) async throws -> StepVerification {
            ingested.append(frame.timestamp)
            if failing { throw CancellationError() }
            return StepVerification(
                stepID: "step", verdict: .incomplete, detectability: .strong, deltaPixels: 1, framesUsed: 1,
                completeFraction: 0, incompleteFraction: 1, registrationQuality: registration.quality,
                timestamp: frame.timestamp
            )
        }
        func latestDiff() -> BuildDiff? { BuildDiff(stepID: "step", observations: [], framesUsed: ingested.count) }
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

    /// Submits a frame and waits until the controller has published it.
    private func judge(_ controller: StepVerificationController, at timestamp: TimeInterval) async {
        controller.submit(frame: frame(at: timestamp), registration: registration)
        for _ in 0..<1_000 where controller.verification?.timestamp != timestamp {
            await Task.yield()
        }
    }

    private func windows(_ collector: WindowCollector, count: Int) async -> [VerificationWindowCapture] {
        for _ in 0..<1_000 where await collector.windows.count < count {
            await Task.yield()
        }
        return await collector.windows
    }

    func testWindowOnVerdictChangeOnlyWhenRecording() async {
        let collector = WindowCollector()
        let controller = StepVerificationController(makeVerifier: { ScriptedVerifier([.incomplete, .incomplete, .complete]) })
        await controller.begin(stepID: "step", completedSnapshot: emptySnapshot, deltaSnapshot: emptySnapshot, stepIndex: 3)
        controller.setWindowSink(collector)
        let staged = StagedVerificationDeclaration(
            scenario: .complete, lighting: .bright, occlusion: .none, physicalCase: true, legalUseConfirmed: true
        )
        controller.setStagedVerification(staged)
        await judge(controller, at: 1.0)
        await judge(controller, at: 2.0)
        await judge(controller, at: 6.0)
        let changed = await windows(collector, count: 1)
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.trigger, .verdictChange)
        XCTAssertEqual(changed.first?.samples.map(\.frame.timestamp), [1.0, 2.0, 6.0])
        XCTAssertEqual(changed.first?.verification.verdict, .complete)
        XCTAssertEqual(changed.first?.stepIndex, 3)
        XCTAssertEqual(changed.first?.staged, staged)

        controller.recordWindow(trigger: .confirm)
        let confirmed = await windows(collector, count: 2)
        XCTAssertEqual(confirmed.last?.trigger, .confirm)

        // Without a sink nothing is buffered or sent.
        controller.setWindowSink(nil)
        controller.recordWindow(trigger: .stepExit)
        await Task.yield()
        let after = await collector.windows
        XCTAssertEqual(after.count, 2)
    }

    func testStopEmptiesTheWindow() async {
        let collector = WindowCollector()
        let controller = StepVerificationController(makeVerifier: { ScriptedVerifier([.incomplete]) })
        await controller.begin(stepID: "step", completedSnapshot: emptySnapshot, deltaSnapshot: emptySnapshot)
        controller.setWindowSink(collector)
        await judge(controller, at: 1.0)
        controller.stop()
        // After a stop there is no verdict and no buffered frame to keep.
        controller.recordWindow(trigger: .stepExit)
        await Task.yield()
        let collected = await collector.windows
        XCTAssertTrue(collected.isEmpty)
    }

    private func shadowed(
        _ shadow: ShadowFake, enabled: Bool = true
    ) async -> StepVerificationController {
        let controller = StepVerificationController(
            makeVerifier: { ScriptedVerifier([.complete]) },
            makeShadow: { shadow },
            shadowEnabled: { enabled }
        )
        await controller.begin(stepID: "step", completedSnapshot: emptySnapshot, deltaSnapshot: emptySnapshot)
        return controller
    }

    private func shadowIngests(_ shadow: ShadowFake, count: Int) async -> [TimeInterval] {
        for _ in 0..<1_000 where await shadow.ingested.count < count {
            await Task.yield()
        }
        return await shadow.ingested
    }

    func testShadowNeverPublishes() async {
        let shadow = ShadowFake()
        let controller = await shadowed(shadow)
        await judge(controller, at: 1.0)
        _ = await shadowIngests(shadow, count: 1)
        for _ in 0..<100 where controller.lastShadowVerdict == nil { await Task.yield() }
        XCTAssertEqual(controller.verification?.verdict, .complete, "the user sees the verifier, never the shadow")
        XCTAssertEqual(controller.lastShadowVerdict?.verdict, .incomplete)
        XCTAssertNotNil(controller.lastShadowDiff)
    }

    func testShadowAbsentWhenToggleOff() async {
        let shadow = ShadowFake()
        let controller = await shadowed(shadow, enabled: false)
        await judge(controller, at: 1.0)
        await Task.yield()
        let begins = await shadow.begins
        let ingested = await shadow.ingested
        XCTAssertEqual(begins, 0)
        XCTAssertTrue(ingested.isEmpty)
        XCTAssertNil(controller.lastShadowVerdict)
    }

    func testShadowSeesTheSameFrames() async {
        let shadow = ShadowFake()
        let controller = await shadowed(shadow)
        for timestamp in [1.0, 2.0, 3.0] { await judge(controller, at: timestamp) }
        let ingested = await shadowIngests(shadow, count: 3)
        XCTAssertEqual(ingested, [1.0, 2.0, 3.0])
    }

    func testShadowPausesWhenSuspended() async {
        let shadow = ShadowFake()
        let controller = await shadowed(shadow)
        await judge(controller, at: 1.0)
        _ = await shadowIngests(shadow, count: 1)
        controller.suspend()
        controller.submit(frame: frame(at: 2.0), registration: registration)
        for _ in 0..<50 { await Task.yield() }
        let ingested = await shadow.ingested
        XCTAssertEqual(ingested, [1.0])
    }

    func testShadowErrorIsIgnored() async {
        let shadow = ShadowFake()
        await shadow.fail()
        let controller = await shadowed(shadow)
        await judge(controller, at: 1.0)
        _ = await shadowIngests(shadow, count: 1)
        XCTAssertEqual(controller.verification?.verdict, .complete)
        XCTAssertNil(controller.lastShadowVerdict)
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

    func testSuspensionRefusesFramesAndDropsTheResultInFlight() async {
        let verifier = GatedVerifier()
        let controller = await makeController(verifier)

        controller.submit(frame: frame(at: 1.0), registration: registration)
        await verifier.waitForHeldIngest()
        controller.suspend()
        controller.submit(frame: frame(at: 1.5), registration: registration)
        await verifier.release()
        for _ in 0..<50 { await Task.yield() }

        var ingested = await verifier.ingested
        XCTAssertEqual(ingested, [1.0], "no frame reaches the verifier during a photo check")
        XCTAssertNil(controller.verification, "a verdict finished during the check must not publish")
        XCTAssertFalse(controller.isStablyComplete)

        controller.resume()
        controller.submit(frame: frame(at: 2.0), registration: registration)
        await waitForIngests(verifier, count: 2)
        for _ in 0..<50 { await Task.yield() }
        ingested = await verifier.ingested
        XCTAssertEqual(ingested, [1.0, 2.0])
        XCTAssertEqual(controller.verification?.timestamp, 2.0)
        XCTAssertFalse(controller.isStablyComplete, "stability is re-earned after a resume")
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
