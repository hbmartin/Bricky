import XCTest
import simd
@testable import Bricky

/// The composite estimator is the only place that sees both recovery legs, so
/// it owns two facts nothing else can report: how long the user actually
/// waited, and whether the geometric pass was tried at all. Both feed release
/// gates (ADR 0010), so both are regression-tested here.
final class CompositeRecoveryEstimatorTests: XCTestCase {
    /// A fallback that reports a fixed, deliberately small latency — standing
    /// in for `HierarchicalRecoveryEstimator`, which times only its own leg.
    private struct StubFallback: RecoveryEstimating {
        let latencyMilliseconds: Int
        let delay: Duration

        func estimate(
            captures: [RecoveryCapture],
            model: InstructionPlan,
            alignment: ARAlignment
        ) async throws -> RecoveryEstimate {
            try await Task.sleep(for: delay)
            return RecoveryEstimate(
                rankedStepIDs: ["main.ldr#3"],
                certainty: .medium,
                modelRevision: "stub-vlm",
                latencyMilliseconds: latencyMilliseconds,
                captureIDs: captures.map(\.id),
                insufficiencyCause: nil,
                method: .vlm
            )
        }
    }

    /// The plan is inert in these tests — with no geometric leg it is only
    /// forwarded to the stub — so it carries the minimum a plan can.
    private var plan: InstructionPlan {
        InstructionPlan(
            id: UUID(),
            title: "composite",
            sourceFilename: "main.ldr",
            sourceSHA256: String(repeating: "0", count: 64),
            importedAt: .now,
            document: InstructionDocument(
                rootSectionName: "main.ldr",
                sections: [],
                orphanSectionNames: [],
                diagnostics: [],
                partPackVersion: "2026-07",
                billOfMaterials: [],
                bounds: nil
            ),
            steps: [],
            placementTimeline: []
        )
    }

    private var alignment: ARAlignment {
        ARAlignment(id: UUID(), transform: matrix_identity_float4x4, isTracking: true)
    }

    func testFallbackWithoutAGeometricLegIsLabelledVLM() async throws {
        let composite = CompositeRecoveryEstimator(
            geometric: nil,
            fallback: StubFallback(latencyMilliseconds: 11_000, delay: .zero),
            thermalState: { .nominal }
        )
        let estimate = try await composite.estimate(
            captures: [],
            model: plan,
            alignment: alignment
        )
        // No geometric pass was possible, so there is no wasted attempt to
        // account for — but the composite still owns the wall clock.
        XCTAssertEqual(estimate.method, .vlm)
        XCTAssertNotEqual(
            estimate.latencyMilliseconds, 11_000,
            "the composite must report its own wall clock, not the fallback's self-report"
        )
    }

    func testCompositeLatencyCoversTheWholeRecoveryNotJustTheFallbackLeg() async throws {
        let sleep = Duration.milliseconds(120)
        let composite = CompositeRecoveryEstimator(
            geometric: nil,
            fallback: StubFallback(latencyMilliseconds: 1, delay: sleep),
            thermalState: { .nominal }
        )
        let estimate = try await composite.estimate(
            captures: [],
            model: plan,
            alignment: alignment
        )
        // The stub claims 1 ms. Before the composite owned the clock, that
        // self-report is what reached the benchmark row and the 20 s gate.
        XCTAssertGreaterThanOrEqual(estimate.latencyMilliseconds, 100)
    }

    /// A geometric leg that cannot conclude: the plan has no steps to fit.
    private func inconclusiveGeometric() throws -> GeometricRecoveryEstimator {
        let frame = RegistrationFrameInput(
            depth: [], confidence: [], rawDepth: nil, rawConfidence: nil, width: 0, height: 0,
            depthIntrinsics: matrix_identity_float3x3, worldFromCamera: matrix_identity_float4x4, timestamp: 0
        )
        let root = FileManager.default.temporaryDirectory
        do {
            return try GeometricRecoveryEstimator(frame: frame, sourceRoot: root, partPackRoot: root)
        } catch {
            throw XCTSkip("Metal unavailable in this test environment")
        }
    }

    func testWithoutAFallbackAnInconclusiveDepthFitHandsOverToTheUser() async throws {
        // Geometric recovery is not gated on VLM admission: with no admitted
        // model it still runs, and an inconclusive fit is reported honestly.
        let composite = CompositeRecoveryEstimator(geometric: try inconclusiveGeometric(), fallback: nil)
        let estimate = try await composite.estimate(captures: [], model: plan, alignment: alignment)
        XCTAssertEqual(estimate.certainty, .insufficient)
        XCTAssertEqual(estimate.method, .geometric)
        XCTAssertEqual(estimate.insufficiencyCause, .geometricInconclusiveWithoutFallback)
        XCTAssertTrue(estimate.rankedStepIDs.isEmpty)
    }

    func testAHotDeviceStartsNoVLMRecovery() async throws {
        for thermal in [ProcessInfo.ThermalState.serious, .critical] {
            let composite = CompositeRecoveryEstimator(
                geometric: nil,
                fallback: StubFallback(latencyMilliseconds: 5, delay: .zero),
                thermalState: { thermal }
            )
            let estimate = try await composite.estimate(captures: [], model: plan, alignment: alignment)
            XCTAssertEqual(estimate.certainty, .insufficient)
            XCTAssertEqual(estimate.insufficiencyCause, .thermalDeferred)
            XCTAssertEqual(estimate.method, .vlm)
            XCTAssertTrue(estimate.rankedStepIDs.isEmpty, "the fallback must not have run")
        }
        let fair = CompositeRecoveryEstimator(
            geometric: nil,
            fallback: StubFallback(latencyMilliseconds: 5, delay: .zero),
            thermalState: { .fair }
        )
        let estimate = try await fair.estimate(captures: [], model: plan, alignment: alignment)
        XCTAssertEqual(estimate.rankedStepIDs, ["main.ldr#3"])
    }

    func testThePolicyWithholdsRecoveryBeforeChecks() {
        XCTAssertEqual(InferencePolicy.decide(.recovery, thermal: .fair), .allowed)
        XCTAssertEqual(InferencePolicy.decide(.recovery, thermal: .serious), .geometricOnly)
        XCTAssertEqual(InferencePolicy.decide(.check, thermal: .serious), .allowed, "a single check still runs")
        XCTAssertEqual(InferencePolicy.decide(.recovery, thermal: .critical), .geometricOnly)
        XCTAssertEqual(InferencePolicy.decide(.check, thermal: .critical), .deferred)
    }

    func testWithNeitherLegTheUserIsToldToPickManually() async {
        let composite = CompositeRecoveryEstimator(geometric: nil, fallback: nil)
        do {
            _ = try await composite.estimate(captures: [], model: plan, alignment: alignment)
            XCTFail("an estimate without any leg must not be invented")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("manually"))
        }
    }

    func testMillisecondsConversionMatchesTheEstimatorsOwnArithmetic() {
        XCTAssertEqual(CompositeRecoveryEstimator.milliseconds(.seconds(2)), 2_000)
        XCTAssertEqual(CompositeRecoveryEstimator.milliseconds(.milliseconds(1_500)), 1_500)
        XCTAssertEqual(CompositeRecoveryEstimator.milliseconds(.zero), 0)
    }

    func testRestampPreservesTheEstimateAndReplacesOnlyMethodAndLatency() {
        let original = RecoveryEstimate(
            rankedStepIDs: ["main.ldr#3", "main.ldr#4"],
            certainty: .high,
            modelRevision: "stub-vlm",
            latencyMilliseconds: 1,
            captureIDs: [],
            insufficiencyCause: .finalPassUnmatched,
            method: .vlm
        )
        let restamped = original.restamped(method: .composite, latencyMilliseconds: 17_500)
        XCTAssertEqual(restamped.method, .composite)
        XCTAssertEqual(restamped.latencyMilliseconds, 17_500)
        // The revision still names the weights that produced the ranking; the
        // method, not the revision, is what says which pipeline ran.
        XCTAssertEqual(restamped.modelRevision, "stub-vlm")
        XCTAssertEqual(restamped.rankedStepIDs, original.rankedStepIDs)
        XCTAssertEqual(restamped.certainty, original.certainty)
        XCTAssertEqual(restamped.insufficiencyCause, original.insufficiencyCause)
    }
}
