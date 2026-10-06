import Foundation

/// The two-sided score of a solved fit against observed depth, shared by
/// geometric recovery and the suggested placement (M2.7): reward the
/// solver's inliers over the visible surface, and charge both observed
/// structure the fit cannot explain (depth well in front of it) and
/// surface the fit predicts where none is seen (depth well behind it).
enum FitScoring {
    struct Result: Equatable, Sendable {
        let score: Float
        let unexplainedFraction: Float
        let phantomFraction: Float
    }

    static func score(
        solve: DepthICPTracker.SolveResult,
        expected: ExpectedDepthMap,
        observed: [Float32],
        confidence: [UInt8],
        minimumConfidence: UInt8,
        unexplainedGap: Float,
        unexplainedWeight: Float
    ) -> Result {
        var covered = 0
        var unexplained = 0
        var phantom = 0
        for index in expected.depth.indices where expected.depth[index] > 0 {
            guard confidence[index] >= minimumConfidence else { continue }
            let depth = observed[index]
            guard depth.isFinite, depth > 0 else { continue }
            covered += 1
            if depth < expected.depth[index] - unexplainedGap {
                unexplained += 1
            } else if depth > expected.depth[index] + unexplainedGap {
                phantom += 1
            }
        }
        let unexplainedFraction = covered > 0 ? Float(unexplained) / Float(covered) : 1
        let phantomFraction = covered > 0 ? Float(phantom) / Float(covered) : 1
        let score = solve.quality.inlierFraction
            * min(1, solve.visibleFraction * 2)
            - unexplainedWeight * (unexplainedFraction + phantomFraction)
        return Result(score: score, unexplainedFraction: unexplainedFraction, phantomFraction: phantomFraction)
    }
}
