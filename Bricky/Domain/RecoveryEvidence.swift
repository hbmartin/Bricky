// The evidence interchange contract (trace rows, session files, bundle
// manifest, benchmark rows, board layout) lives in RecoveryEvidenceKit so the
// app and the bricky-harness CLI share one definition. Re-exported so the
// rest of the app uses the types unqualified.
import Foundation
@_exported import RecoveryEvidenceKit
import simd

/// What `GeometricRecoveryEstimator` needs from an evidence recorder. A
/// protocol rather than `RecoveryEvidenceRecorder` itself, because the
/// recorder imports MLX and the geometric stack must also compile into the
/// macOS SyntheticRGBD tool.
protocol GeometricFitRecording: Actor {
    nonisolated var sessionID: UUID { get }
    func recordFits(_ records: [GeometricFitRecord])
}

/// Keeps fits in memory instead of writing `fits.ndjson`: what a Mac replay
/// of a recorded recovery records through, so its fits can be compared with
/// the device's.
actor GeometricFitCollector: GeometricFitRecording {
    nonisolated let sessionID: UUID
    private(set) var records: [GeometricFitRecord] = []

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    func recordFits(_ records: [GeometricFitRecord]) {
        self.records.append(contentsOf: records)
    }
}

/// Ground-truth mapping a benchmark row needs from the instruction plan.
/// `expected_step_index` uses authored step numbers with 0 meaning step zero
/// (not started) — the same semantics as the scorer's example fixtures.
struct RecoveryBenchmarkInputs: Sendable {
    let expectedCompletedCount: Int
    let expectedStepID: String
    /// Authored step number by step identifier, including step zero → 0.
    let stepNumbersByID: [String: Int]

    init(expectedCompletedCount: Int, expectedStepID: String, stepNumbersByID: [String: Int]) {
        self.expectedCompletedCount = expectedCompletedCount
        self.expectedStepID = expectedStepID
        self.stepNumbersByID = stepNumbersByID
    }

    init(plan: InstructionPlan, expectedCompletedCount: Int) {
        let clamped = min(max(0, expectedCompletedCount), plan.steps.count)
        var numbers = [plan.stepZeroID: 0]
        for step in plan.steps {
            numbers[step.id] = step.index
        }
        self.init(
            expectedCompletedCount: clamped,
            expectedStepID: clamped == 0 ? plan.stepZeroID : plan.steps[clamped - 1].id,
            stepNumbersByID: numbers
        )
    }
}

extension EvidenceCaptureRecord {
    /// Bridges the app's domain capture into the interchange record. The
    /// image path is rewritten to the session-relative copy the recorder makes.
    init(_ capture: RecoveryCapture, worldFromModel: simd_float4x4? = nil) {
        self.init(
            captureID: capture.id,
            imageRelativePath: "captures/\(capture.id.uuidString).jpg",
            cameraTransform: capture.cameraTransform,
            cameraIntrinsics: capture.cameraIntrinsics,
            cameraImageResolution: capture.cameraImageResolution,
            alignmentID: capture.alignmentID,
            angle: capture.angle.rawValue,
            capturedAt: capture.capturedAt,
            // Column-major, as `cameraTransform` is recorded.
            worldFromModel: worldFromModel.map { matrix in
                (0..<4).flatMap { column in (0..<4).map { row in matrix[column][row] } }
            }
        )
    }
}

extension EvidenceSessionFile.EstimateSummary {
    /// Carries the estimate's own method and revision, not the session
    /// header's: the header records which VLM was loadable when the session
    /// opened, which says nothing about whether the geometric path is what
    /// actually answered.
    init(_ estimate: RecoveryEstimate) {
        self.init(
            rankedStepIDs: estimate.rankedStepIDs,
            certainty: estimate.certainty.rawValue,
            insufficiencyCause: estimate.insufficiencyCause?.rawValue,
            latencyMilliseconds: estimate.latencyMilliseconds,
            method: estimate.method,
            modelRevision: estimate.modelRevision
        )
    }
}
