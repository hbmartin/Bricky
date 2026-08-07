import Foundation
import simd

/// What LiDAR depth can even see of a step's delta from the current view,
/// computed from the expected renders alone before any claim is made
/// (ADR 0008). Small plates and flush tiles are below sensor physics; the
/// verifier abstains there instead of guessing.
enum DeltaDetectability: String, Sendable, Codable {
    /// Median expected depth change ≥ 6 mm over ≥ 80 px: depth may judge alone.
    case strong
    /// 3–6 mm or a small footprint: depth evidence exists but a lone depth
    /// verdict of "complete" is not trustworthy. Until the RGB support term
    /// lands, marginal deltas may be judged incomplete or misplaced but
    /// never complete.
    case marginal
    /// Below noise or nearly invisible: geometric verification abstains.
    case undetectable
}

enum UncertainReason: String, Sendable, Codable {
    case registrationNotLocked
    case poseAmbiguous
    case deltaUndetectable
    case occludedView
    case insufficientEvidence
}

enum StepVerdict: Sendable, Codable, Equatable {
    case complete
    case incomplete
    /// The delta's geometry is present but at a lattice offset (studs in the
    /// model's x/z) — the classic one-stud-off placement.
    case misplaced(offsetStuds: SIMD2<Int>)
    case uncertain(UncertainReason)

    var isComplete: Bool { self == .complete }
}

/// One verification outcome with the evidence that produced it. Advisory by
/// contract: the user confirms every step (ADR 0001); nothing auto-advances.
struct StepVerification: Sendable {
    let stepID: String
    let verdict: StepVerdict
    let detectability: DeltaDetectability
    /// Pixels of the delta's visible footprint in the depth grid.
    let deltaPixels: Int
    let framesUsed: Int
    /// Vote fractions over classified delta pixels, for debugging and
    /// benchmark rows.
    let completeFraction: Float
    let incompleteFraction: Float
    let registrationQuality: RegistrationQuality
    let timestamp: TimeInterval
}
