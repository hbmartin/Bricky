import Foundation

/// One ±1-stud lattice contest a verification window carries: on pixels
/// where the authored placement and the one shifted by `offset_studs`
/// predict different depth, how often the observation matched each.
/// Counted since the step began, like `frames_used`. Stud keypoints
/// (ADR 0020) must show these are where the verifier goes wrong before
/// anything learned is added.
public struct LatticeContestRecord: Codable, Sendable, Equatable {
    /// `[dx, dz]` in studs along the model's x and z.
    public var offsetStuds: [Int]
    public var winsComplete: Int
    public var winsShifted: Int

    public init(offsetStuds: [Int], winsComplete: Int, winsShifted: Int) {
        self.offsetStuds = offsetStuds
        self.winsComplete = winsComplete
        self.winsShifted = winsShifted
    }

    enum CodingKeys: String, CodingKey {
        case offsetStuds = "offset_studs"
        case winsComplete = "wins_complete"
        case winsShifted = "wins_shifted"
    }
}

/// One alternative's contest against a placement as authored, in a build
/// diff (M2.3): the same exclusive-evidence count, per placement.
public struct HypothesisTallyRecord: Codable, Sendable, Equatable {
    /// `[dx, dz, dy, quarter_turns]`, the layout of
    /// `BuildDiffRecord.Placement.offset`.
    public var offset: [Int]
    public var winsPresent: Int
    public var winsAlternative: Int

    public init(offset: [Int], winsPresent: Int, winsAlternative: Int) {
        self.offset = offset
        self.winsPresent = winsPresent
        self.winsAlternative = winsAlternative
    }

    enum CodingKeys: String, CodingKey {
        case offset
        case winsPresent = "wins_present"
        case winsAlternative = "wins_alternative"
    }
}
