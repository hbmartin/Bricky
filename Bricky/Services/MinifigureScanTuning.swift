import Foundation

/// Centralized tuning constants for the minifigure identification
/// pipeline. These values were derived empirically (see the comments at
/// each former call site) and previously lived as inline literals
/// scattered across `MinifigureIdentificationService` and its
/// extensions. Collecting the *repeated* and semantically-meaningful
/// ones here keeps them discoverable and adjustable in one place.
///
/// Constants that are unique to a single algorithm step and carry their
/// rationale in surrounding comments are intentionally left inline —
/// pulling every literal into this enum would obscure intent more than
/// it would help.
enum MinifigureScanTuning {

    // MARK: - Confidence gates

    /// Local-confidence floor below which Phase 3 cloud validation is
    /// attempted. At or above this, the on-device result is trusted and
    /// no network call is made. Used by the cloud-fallback gate in the
    /// orchestrator. (Distinct from `torsoConfidentScore`, which happens
    /// to share the same numeric value but governs cascade weighting.)
    static let cloudConfidenceFloor: Double = 0.80

    /// Torso color-match score at or above which the color cascade
    /// treats the torso as the primary key (torso dominates, auxiliary
    /// parts contribute only small consistency bonuses). Below this, the
    /// cascade falls back to joint inference across head/hair/legs.
    static let torsoConfidentScore: Double = 0.80

    // MARK: - Reference image fetch budget

    /// Maximum number of candidate reference thumbnails to download
    /// opportunistically during Phase 2 visual refinement.
    static let maxReferenceFetch: Int = 16

    /// Overall wall-clock timeout for the opportunistic reference fetch.
    /// On slow/offline networks the pipeline silently falls back to
    /// color-only ranking.
    static let referenceFetchTimeout: TimeInterval = 2.5

    // MARK: - Phase 2 blend weights

    /// Weight given to the Phase 1 color-cascade confidence when blending
    /// the final Phase 2 score. Keeps color-verified candidates ahead of
    /// CLIP-injected ones that have no Phase 1 color evidence.
    static let colorCascadeWeight: Double = 0.20

    /// Embedding-discrimination tiers that adjust how much the DINOv2
    /// embedding signal is trusted versus the visual feature-print
    /// signal. Higher discrimination → trust the embedding more.
    static let embeddingDiscriminationStrong: Double = 0.05
    static let embeddingDiscriminationModerate: Double = 0.03

    // MARK: - Torso print detection

    /// Perceptual-RGB distance above which a torso-band pixel counts as
    /// "print" (zipper, badge, insignia) rather than base-color noise.
    /// Tuned so jpeg/lighting noise (~20–40) doesn't register but legible
    /// print detail (~80+) does.
    static let printPixelDistanceThreshold: Double = 70
}
