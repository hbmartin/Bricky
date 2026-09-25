// The evidence interchange contract (trace rows, session files, bundle
// manifest, benchmark rows, board layout) lives in RecoveryEvidenceKit so the
// app and the bricky-harness CLI share one definition. Re-exported so the
// rest of the app uses the types unqualified.
import Foundation
@_exported import RecoveryEvidenceKit

/// What `GeometricRecoveryEstimator` needs from an evidence recorder. A
/// protocol rather than `RecoveryEvidenceRecorder` itself, because the
/// recorder imports MLX and the geometric stack must also compile into the
/// macOS SyntheticRGBD tool.
protocol GeometricFitRecording: Actor {
    nonisolated var sessionID: UUID { get }
    func recordFits(_ records: [GeometricFitRecord])
}

extension EvidenceCaptureRecord {
    /// Bridges the app's domain capture into the interchange record. The
    /// image path is rewritten to the session-relative copy the recorder makes.
    init(_ capture: RecoveryCapture) {
        self.init(
            captureID: capture.id,
            imageRelativePath: "captures/\(capture.id.uuidString).jpg",
            cameraTransform: capture.cameraTransform,
            cameraIntrinsics: capture.cameraIntrinsics,
            cameraImageResolution: capture.cameraImageResolution,
            alignmentID: capture.alignmentID,
            angle: capture.angle.rawValue,
            capturedAt: capture.capturedAt
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
