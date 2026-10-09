import Foundation
import simd

/// Re-runs a recorded geometric recovery from its evidence session (ADR 0010,
/// ADR 0007 note of 2026-10-08). The session's center depth frame and the
/// alignment the device fit it from are the estimator's whole input, so the
/// same plan and part pack reproduce the device's fits. Shared by the app's
/// tests and SyntheticRGBD `--replay-bundle --suite recovery`, so the tests
/// exercise exactly what the tool runs. Foundation and simd only: it must
/// compile into the macOS tool.
enum GeometricRecoveryReplay {
    struct Input: Sendable {
        let frame: RegistrationFrameInput
        let alignment: ARAlignment
        let captureIDs: [UUID]
    }

    /// Why a session cannot be replayed.
    enum Skip: String, Error, Sendable {
        /// No depth frame was recorded: a VLM-only session.
        case noDepthFrame = "no_depth_frame"
        /// The frame has no alignment: recorded before 2026-10-08.
        case noAlignment = "no_alignment"
    }

    struct Outcome: Sendable {
        /// Nil when the fit was inconclusive or the estimator threw; the
        /// replay's verdict is then insufficient, as the device's is without
        /// a fallback.
        let estimate: RecoveryEstimate?
        let fits: [GeometricFitRecord]
        let latencyMilliseconds: Int
        let error: String?
    }

    /// The frame the device fit against — the center capture's, as
    /// `RecoveryEvidenceRecorder.recordRecoveryInputs` records it — and the
    /// alignment it started from. Throws `Skip` when the session lacks
    /// either, and the planes' load error when they cannot be read.
    static func input(for session: EvidenceBundleReader.Session) throws -> Input {
        let captures = session.file.captures
        let center = captures.first(where: { $0.angle == CaptureAngle.center.rawValue }) ?? captures.first
        let record = session.depthFrames.first(where: { $0.captureID == center?.captureID }) ?? session.depthFrames.first
        guard let record else { throw Skip.noDepthFrame }
        guard let coarse = record.coarseWorldFromModel, coarse.count == 16 else { throw Skip.noAlignment }
        let planes = try EvidenceDepthPlanes.load(record, in: session.directory)
        let alignmentID = captures.first(where: { $0.captureID == record.captureID })?.alignmentID ?? UUID()
        return Input(
            frame: RegistrationFrameInput(record: record, planes: planes),
            alignment: ARAlignment(id: alignmentID, transform: simd_float4x4(rowMajor: coarse), isTracking: true),
            captureIDs: captures.map(\.captureID)
        )
    }

    /// Runs the estimator on `input`, collecting its fits in memory. Fits
    /// carry `sessionID`, so replayed records name the session they replay.
    static func replay(
        _ input: Input,
        sessionID: UUID,
        plan: InstructionPlan,
        geometry: PlacementGeometry,
        sourceRoot: URL,
        partPackRoot: URL,
        renderer: ExpectedDepthRenderer,
        configuration: GeometricRecoveryEstimator.Configuration = GeometricRecoveryEstimator.Configuration()
    ) async throws -> Outcome {
        let collector = GeometricFitCollector(sessionID: sessionID)
        let started = ContinuousClock.now
        var estimate: RecoveryEstimate?
        var failure: String?
        do {
            let estimator = try GeometricRecoveryEstimator(
                frame: input.frame, sourceRoot: sourceRoot, partPackRoot: partPackRoot,
                configuration: configuration, recorder: collector, renderer: renderer, geometry: geometry
            )
            estimate = try await estimator.estimate(model: plan, alignment: input.alignment, captureIDs: input.captureIDs)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The composite estimator steps aside on any geometric error, so
            // the device's verdict was insufficient too.
            failure = String(describing: error)
        }
        let elapsed = started.duration(to: .now).components
        let milliseconds = Int(elapsed.seconds) * 1_000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        return Outcome(estimate: estimate, fits: await collector.records, latencyMilliseconds: milliseconds, error: failure)
    }

    /// Whether the replay produced exactly the device's fits: the same
    /// candidates, every measurement bit for bit.
    static func fitsMatch(recorded: [GeometricFitRecord], replayed: [GeometricFitRecord]) -> Bool {
        let device = recorded.sorted { $0.candidateIndex < $1.candidateIndex }
        let again = replayed.sorted { $0.candidateIndex < $1.candidateIndex }
        guard device.count == again.count else { return false }
        for (original, replay) in zip(device, again) where !original.isSameFit(as: replay) {
            return false
        }
        return true
    }

    /// Whether the replay reached the geometric verdict the device did. Nil
    /// when the device's outcome does not say what the geometric leg
    /// concluded: no estimate, no method, or a VLM-only session.
    static func estimateMatches(_ replayed: RecoveryEstimate?, recorded: EvidenceSessionFile.EstimateSummary?) -> Bool? {
        guard let recorded, let method = recorded.method else { return nil }
        switch method {
        case .vlm:
            return nil
        case .composite:
            // The geometric leg ran and did not conclude.
            return replayed == nil
        case .geometric:
            guard recorded.certainty != RecoveryCertainty.insufficient.rawValue else { return replayed == nil }
            guard let replayed else { return false }
            return replayed.rankedStepIDs == recorded.rankedStepIDs
                && replayed.certainty.rawValue == recorded.certainty
                && replayed.modelRevision == recorded.modelRevision
        }
    }
}
