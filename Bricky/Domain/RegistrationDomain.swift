import Foundation
import simd

/// One depth observation handed to the registration tracker: a copied-out
/// LiDAR depth map with its confidence, intrinsics scaled to the depth
/// resolution, and the camera pose that produced it. Values are copies —
/// an `ARFrame` is never retained past the delegate callback.
struct RegistrationFrameInput: Sendable {
    /// Row-major smoothed depth in meters, `width * height` values — the
    /// ICP tracking input.
    let depth: [Float32]
    /// `ARConfidenceLevel` raw values, same layout as `depth`.
    let confidence: [UInt8]
    /// Raw (unsmoothed) depth and its confidence for the verifier: temporal
    /// smoothing lags freshly placed bricks, so verification evidence must
    /// come from the current frame. Absent when the session provides no raw
    /// scene depth.
    let rawDepth: [Float32]?
    let rawConfidence: [UInt8]?
    let width: Int
    let height: Int
    /// Camera intrinsics rescaled from the capture resolution to
    /// `width x height`, so projecting a world point yields depth-map pixels.
    let depthIntrinsics: simd_float3x3
    let worldFromCamera: simd_float4x4
    let timestamp: TimeInterval
    /// Auxiliary channels, filled only when asked for: while evidence
    /// capture is on (ADR 0007 amendment 2), or the colour plane alone while
    /// the colour term runs (amendment 3). Tracking never reads them; only
    /// the colour term reads `colour`, with the authority its mode allows.
    /// RGB8, interleaved, the camera image box-filtered onto the depth grid.
    var colour: [UInt8]? = nil
    /// How `colour` was converted, e.g. `rgb8_bt709_full`.
    var colourEncoding: String? = nil
    /// 1 where person segmentation marks an occluder (a hand), else 0.
    var occluderMask: [UInt8]? = nil
    /// Evidence only: how long the auxiliary channels above took to
    /// extract, in milliseconds (Phase 1 budget: p95 ≤ 3 ms). Nil when none
    /// was asked for.
    var auxiliaryExtractMilliseconds: Double? = nil
    /// Evidence only: the person-segmentation buffer the mask was resampled
    /// from, as ARKit delivered it, so its size and row alignment can be
    /// checked on device rather than assumed.
    var segmentationWidth: Int? = nil
    var segmentationHeight: Int? = nil
    var segmentationBytesPerRow: Int? = nil
}

/// An oriented point sample of the cumulative expected model surface, in the
/// model's own frame (meters). The unit ICP fits against depth.
struct ModelSurfaceSample: Sendable {
    let points: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    /// Resolved LDraw colour code per point, for colour-assisted
    /// correspondence weighting and verifier evidence.
    let colorCodes: [Int]
    /// The step index this sample was built for; the tracker re-fits when it
    /// changes.
    let stepIndex: Int
}

enum RegistrationState: String, Sendable, Codable {
    /// No alignment exists; the ghost has not been placed.
    case unplaced
    /// Manual placement exists but the tracker has not yet converged on it.
    case coarse
    /// The solver is iterating but has not met the lock thresholds.
    case refining
    /// Converged, unambiguous, and within quality bounds — verification may run.
    case locked
    /// Converged but a stud-lattice shift or symmetric yaw explains the depth
    /// almost as well; verification is refused until the user disambiguates.
    case ambiguous
    /// Correspondence collapsed or ARKit tracking was lost.
    case lost
}

/// One competing lattice hypothesis the tracker scores against the current
/// pose (ADR 0009), named in the model frame: ±1 stud along the model's x or
/// z axis, or a yaw about the model centroid.
enum LatticeAlternative: String, Sendable, Codable, CaseIterable {
    case shiftXPositive = "shift_x_pos"
    case shiftXNegative = "shift_x_neg"
    case shiftZPositive = "shift_z_pos"
    case shiftZNegative = "shift_z_neg"
    case yaw180 = "yaw_180"
    case yaw90 = "yaw_90"
}

/// Fit-quality evidence for the current registration estimate.
struct RegistrationQuality: Sendable, Codable, Equatable {
    /// Root-mean-square point-to-plane residual over inliers, meters.
    let rmsResidual: Float
    /// Fraction of projected sample points with a confident correspondence.
    let inlierFraction: Float
    /// Minimum cost ratio of the competing lattice hypotheses (±1 stud in
    /// x/z, and 90°/180° yaw for near-square footprints) against the current
    /// pose. Values near 1.0 mean an alternative explains the depth equally
    /// well; values well above 1.0 mean the pose is distinctive. A margin of
    /// 0 records that no sweep ran (the fit was below the loss floor) and
    /// likewise must never read as distinctive.
    let latticeMargin: Float
    /// The alternative that set `latticeMargin`: the hypothesis that came
    /// closest to explaining the depth. Evidence only — the lock rule reads
    /// the margin alone. Nil when no sweep ran, or when every alternative
    /// left the image and none could compete.
    var latticeRunnerUp: LatticeAlternative? = nil

    static let none = RegistrationQuality(rmsResidual: .infinity, inlierFraction: 0, latticeMargin: 1)
}

/// The tracker's published estimate: where the model frame sits in the world,
/// how sure the solver is, and which step's geometry it was fit against.
struct ModelRegistration: Sendable {
    let alignmentID: UUID
    let worldFromModel: simd_float4x4
    let state: RegistrationState
    let quality: RegistrationQuality
    let fittedStepIndex: Int
    let timestamp: TimeInterval

    /// Verification may only produce a verdict under a locked registration
    /// (ADR 0009); everything else must surface as uncertainty, never as a
    /// step verdict.
    var allowsVerification: Bool { state == .locked }
}
