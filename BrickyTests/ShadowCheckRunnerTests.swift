import BrickyLanguage
import simd
import XCTest
@testable import Bricky

/// The Foundation Models advisor runs beside a photo check in shadow: the
/// primary verdict never waits for it, a new check cancels it, its records
/// land in their own files, and draining it never hangs a finalize.
@MainActor
final class ShadowCheckRunnerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Says "incomplete" and "absent" after `delay`; a cancelled sleep
    /// returns at once.
    private struct SlowAdvisor: StepCheckModelAdvisor {
        let delay: Duration

        func advise(_ input: StepCheckAdviceInput) async -> StepCheckAdvice {
            try? await Task.sleep(for: delay)
            return StepCheckAdvice(standalone: .incomplete, standaloneOutcome: "answered", closed: .absent,
                                   closedOutcome: "answered", milliseconds: 5)
        }
    }

    /// Never returns in any reasonable time and ignores cancellation.
    private struct StuckAdvisor: StepCheckModelAdvisor {
        func advise(_ input: StepCheckAdviceInput) async -> StepCheckAdvice {
            let until = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < until {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return .skipped("stuck")
        }
    }

    private func recorder(staged: StagedFixtureDeclaration? = nil) -> RecoveryEvidenceRecorder {
        RecoveryEvidenceRecorder(root: root, instructionSHA256: "abc123", authoredModelID: UUID(), modelTitle: "Test", stepCount: 6, staged: staged)
    }

    private func outcome(_ result: StepCheckResult = .complete) -> VLMStepCheckService.Outcome {
        var variant = RecoveryInferenceVariant.baseline
        variant.checkTarget = .registered
        return VLMStepCheckService.Outcome(
            result: result, boardJPEG: Data(), variant: variant,
            checkGeometry: CheckGeometryRecord(deltaBox: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2), deltaPixels: 50, gridWidth: 256, gridHeight: 192),
            photoJPEG: Data([1]), targetJPEG: Data([2])
        )
    }

    /// Step `number` (1-based) of a three-step plan.
    private func step(_ number: Int) throws -> AuthoredStep {
        let source = """
        0 Shadow fixture
        0 Name: main.ldr
        1 4 0 0 0 1 0 0 0 1 0 0 0 1 3001.dat
        0 STEP
        1 1 0 -24 0 1 0 0 0 1 0 0 0 1 3001.dat
        0 STEP
        1 14 0 -48 0 1 0 0 0 1 0 0 0 1 3001.dat
        0 STEP
        """
        let document = try LDrawInstructionParser().parse(
            files: [InstructionSourceFile(relativePath: "main.ldr", data: Data(source.utf8))], rootRelativePath: "main.ldr"
        )
        let plan = try InstructionPlanBuilder().build(
            document: document, title: "Fixture", sourceFilename: "main.ldr", sourceSHA256: String(repeating: "a", count: 64)
        )
        return try XCTUnwrap(plan.steps.first { $0.index == number })
    }

    private func shadowFile(_ recorder: RecoveryEvidenceRecorder) -> URL {
        root.appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
            .appendingPathComponent(ShadowCheckTraceV1.filename)
    }

    private func eventually(_ condition: () -> Bool, timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testPrimaryResultPublishesBeforeShadowCompletes() async throws {
        let runner = ShadowCheckRunner(makeAdvisor: { SlowAdvisor(delay: .milliseconds(400)) })
        let recorder = recorder()
        let controller = PhotoCheckController()
        let source = FixedPoseSource()
        let checked = try step(3)
        let task = controller.start(source: source) { _ in
            let outcome = self.outcome()
            runner.start(outcome: outcome, captureID: UUID(), step: checked, recorder: recorder)
            return outcome.result
        }
        await task?.value
        XCTAssertEqual(controller.state, .finished(.complete), "published without waiting for the shadow")
        XCTAssertTrue(runner.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shadowFile(recorder).path))
        await runner.drain(deadline: .seconds(3))
        let traces = await recorder.loadShadowCheckTraces()
        let trace = try XCTUnwrap(traces.first)
        XCTAssertEqual(trace.primaryVerdict, "complete")
        XCTAssertEqual(trace.standaloneVerdict, "incomplete")
        XCTAssertEqual(trace.closedAnswer, "absent")
        XCTAssertEqual(trace.mergedVerdict, "incomplete", "the merge may take a complete away")
        XCTAssertEqual(trace.stepIndex, 2)
        XCTAssertTrue(trace.hadDeltaBox)
        XCTAssertEqual(trace.checkTarget, "registered")
    }

    func testANewCheckCancelsTheShadow() async throws {
        let runner = ShadowCheckRunner(makeAdvisor: { SlowAdvisor(delay: .milliseconds(300)) })
        let recorder = recorder()
        runner.start(outcome: outcome(.complete), captureID: UUID(), step: try step(2), recorder: recorder)
        runner.start(outcome: outcome(.incomplete), captureID: UUID(), step: try step(3), recorder: recorder)
        await runner.drain(deadline: .seconds(3))
        let traces = await recorder.loadShadowCheckTraces()
        XCTAssertEqual(traces.map(\.primaryVerdict), ["incomplete"], "only the later check's shadow records")
    }

    func testDrainNeverHangsOnAStuckAdvisor() async throws {
        let runner = ShadowCheckRunner(makeAdvisor: { StuckAdvisor() })
        let recorder = recorder()
        runner.start(outcome: outcome(), captureID: UUID(), step: try step(2), recorder: recorder)
        let started = ContinuousClock.now
        await runner.drain(deadline: .milliseconds(200))
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        let traces = await recorder.loadShadowCheckTraces()
        XCTAssertTrue(traces.isEmpty, "a run past its deadline records nothing")
    }

    func testShadowRowsAreSeparateFromCheckRows() async throws {
        let staged = StagedFixtureDeclaration(
            expectedCompletedCount: 1, lighting: .bright, occlusion: .none, physicalCase: true, legalUseConfirmed: true
        )
        let recorder = recorder(staged: staged)
        let runner = ShadowCheckRunner(makeAdvisor: { SlowAdvisor(delay: .zero) })
        runner.start(outcome: outcome(.complete), captureID: UUID(), step: try step(2), recorder: recorder)
        await runner.drain(deadline: .seconds(3))
        await recorder.finalize(
            estimate: nil, analysisError: nil,
            groundTruth: EvidenceGroundTruth(kind: .staged, expectedCompletedCount: 1, confirmedAt: nil)
        )
        let directory = shadowFile(recorder).deletingLastPathComponent()
        let rows = try Data(contentsOf: directory.appendingPathComponent(ShadowCheckRowV1.filename))
            .split(separator: UInt8(ascii: "\n"))
            .map { try JSONDecoder().decode(ShadowCheckRowV1.self, from: Data($0)) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.kind, "shadow_check")
        // One step done, step 2 checked: the truth is incomplete, and the
        // VLM's complete was a false one the shadow took away.
        XCTAssertEqual(rows.first?.expectedVerdict, "incomplete")
        XCTAssertEqual(rows.first?.primaryVerdict, "complete")
        XCTAssertEqual(rows.first?.mergedVerdict, "incomplete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(RecoveryEvidenceRecorder.checkRowsFilename).path),
                       "no VLM check trace, so no vlm_check row")
    }
}

/// A locked pose that never changes, for the photo check controller.
@MainActor
private final class FixedPoseSource: RegisteredPoseSource {
    var lockedAlignment: ARAlignment? = ARAlignment(id: UUID(), transform: matrix_identity_float4x4, isTracking: true)
    func suspendVerification() {}
    func resumeVerification() {}
}
