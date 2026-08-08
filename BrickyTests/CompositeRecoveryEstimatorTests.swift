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
            fallback: StubFallback(latencyMilliseconds: 11_000, delay: .zero)
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
            fallback: StubFallback(latencyMilliseconds: 1, delay: sleep)
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
