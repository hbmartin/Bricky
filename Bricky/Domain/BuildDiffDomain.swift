import Foundation
import simd

/// A displacement of one authored placement on the stud lattice: whole
/// studs along model x and z, whole plates up, and quarter turns of yaw
/// about the placement's own origin (M2.3).
struct LatticeOffset: Hashable, Sendable, Codable {
    var dx: Int = 0
    var dz: Int = 0
    var dy: Int = 0
    var quarterTurns: Int = 0

    static let zero = LatticeOffset()

    var isRotation: Bool { quarterTurns % 4 != 0 }
    /// A plate step: depth cannot judge 3.2 mm reliably, so these are
    /// recorded, never acted on (observe-only).
    var isVertical: Bool { dy != 0 }

    enum CodingKeys: String, CodingKey {
        case dx, dz, dy
        case quarterTurns = "quarter_turns"
    }
}

/// What the build diff concluded about one authored placement.
enum PlacementState: Hashable, Sendable {
    case present
    case absent
    /// Present but shifted along the lattice by the offset (x/z only).
    case displaced(LatticeOffset)
    /// Present but turned; only for parts that do not survive the turn.
    case rotated(quarterTurns: Int)
    /// Present, but the colour term sees another colour the model uses
    /// (ADR 0008 amendment, M3.2). Depth never reports it.
    case colourMismatch
    case notObservable(NotObservableReason)

    var name: String {
        switch self {
        case .present: "present"
        case .absent: "absent"
        case .displaced: "displaced"
        case .rotated: "rotated"
        case .colourMismatch: "colour_mismatch"
        case .notObservable: "not_observable"
        }
    }
}

enum NotObservableReason: String, Hashable, Sendable, Codable {
    /// Too little of the placement was visible.
    case occluded
    /// Its depth change is below what LiDAR resolves.
    case undetectable
    /// Visible, but the evidence decides nothing yet.
    case insufficientEvidence = "insufficient_evidence"
}

/// One alternative's exclusive-evidence contest against "present as
/// authored", counted only where the two predict different depth.
struct HypothesisTally: Hashable, Sendable, Codable {
    let offset: LatticeOffset
    var winsPresent = 0
    var winsAlternative = 0

    enum CodingKeys: String, CodingKey {
        case offset
        case winsPresent = "wins_present"
        case winsAlternative = "wins_alternative"
    }
}

/// Per-placement depth votes accumulated across frames.
struct PlacementEvidence: Hashable, Sendable, Codable {
    /// Pixels matching the placement's expected surface.
    var support = 0
    /// Pixels matching what lies behind it, or free space.
    var absence = 0
    /// Pixels matching neither.
    var unexplained = 0
    /// Frames in which some of it was visible.
    var framesSeen = 0
    var tallies: [HypothesisTally] = []
    /// The colour term's reading of this placement, when it ran (M3.2).
    var colour: PlacementColour? = nil

    var classified: Int { support + absence + unexplained }

    enum CodingKeys: String, CodingKey {
        case support, absence, unexplained, tallies, colour
        case framesSeen = "frames_seen"
    }
}

/// The colour term's summary for one placement: its status name
/// (`agrees`, `disagrees`, `inconclusive_<reason>`) and the distances it
/// was decided on, in Oklab.
struct PlacementColour: Hashable, Sendable, Codable {
    var status: String
    var frames: Int
    var authoredDistance: Float?
    var nearestCode: Int?
    var nearestDistance: Float?

    var disagrees: Bool { status == "disagrees" }

    enum CodingKeys: String, CodingKey {
        case status, frames
        case authoredDistance = "authored_distance"
        case nearestCode = "nearest_code"
        case nearestDistance = "nearest_distance"
    }
}

struct PlacementObservation: Hashable, Sendable {
    /// Index into the plan's placement timeline.
    let placement: Int
    let state: PlacementState
    let evidence: PlacementEvidence
}

/// The diff of one step's authored placements against observed depth.
struct BuildDiff: Sendable {
    let stepID: String
    let observations: [PlacementObservation]
    let framesUsed: Int
}
