import Foundation

/// The step a judge verifies: the colour-merged snapshots every judge
/// renders, and, when the plan's timeline was flattened once (M2.0), the
/// segmented geometry and index that per-placement judging needs.
struct StepGeometry: Sendable {
    let completedSnapshot: InstructionGeometrySnapshot
    let deltaSnapshot: InstructionGeometrySnapshot
    /// Nil when the caller has only snapshots.
    let segments: SegmentedGeometry?
    let index: PlacementGeometryIndex?
    /// Placement indices already built, and those this step adds.
    let completedPlacements: Range<Int>
    let deltaPlacements: Range<Int>

    /// Snapshots alone, as callers had before segmented geometry.
    init(completedSnapshot: InstructionGeometrySnapshot, deltaSnapshot: InstructionGeometrySnapshot) {
        self.completedSnapshot = completedSnapshot
        self.deltaSnapshot = deltaSnapshot
        segments = nil
        index = nil
        completedPlacements = 0..<0
        deltaPlacements = 0..<0
    }

    init(
        completedSnapshot: InstructionGeometrySnapshot, deltaSnapshot: InstructionGeometrySnapshot,
        segments: SegmentedGeometry?, index: PlacementGeometryIndex?,
        completedPlacements: Range<Int>, deltaPlacements: Range<Int>
    ) {
        self.completedSnapshot = completedSnapshot
        self.deltaSnapshot = deltaSnapshot
        self.segments = segments
        self.index = index
        self.completedPlacements = completedPlacements
        self.deltaPlacements = deltaPlacements
    }

    /// `step` from a plan's cached geometry.
    init(step: AuthoredStep, geometry: PlacementGeometry) {
        let lower = min(max(0, step.addedPlacementRange.lowerBound), geometry.segments.placementCount)
        let upper = min(max(lower, step.addedPlacementRange.upperBound), geometry.segments.placementCount)
        completedSnapshot = geometry.completedSnapshot(before: step)
        deltaSnapshot = geometry.deltaSnapshot(for: step)
        segments = geometry.segments
        index = geometry.index
        completedPlacements = 0..<lower
        deltaPlacements = lower..<upper
    }
}

/// Anything that judges a step from depth frames under a registration: the
/// geometric verifier, the shadow build diff (M2.3), and test fakes. Kept
/// free of SwiftUI so SyntheticRGBD compiles it.
protocol StepJudging: Actor {
    func begin(stepID: String, geometry: StepGeometry)
    func ingest(frame: RegistrationFrameInput, registration: ModelRegistration) async throws -> StepVerification
    func resetEvidence()
}

extension GeometricStepVerifier: StepJudging {
    func begin(stepID: String, geometry: StepGeometry) {
        begin(stepID: stepID, completedSnapshot: geometry.completedSnapshot, deltaSnapshot: geometry.deltaSnapshot)
    }
}
