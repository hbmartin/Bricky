import Foundation

/// The coarse-to-fine index schedule and step identities shared by the
/// geometric and VLM recovery estimators. Index −1 is step zero (nothing
/// built); index `i` is `plan.steps[i]`.
///
/// Foundation-only on purpose: the geometric recovery stack must compile
/// into the macOS SyntheticRGBD tool, which cannot link UIKit or MLX. These
/// helpers used to live on `HierarchicalRecoveryEstimator`, which imports
/// both, and the tool carried a hand-copied duplicate — exactly the constant
/// drift a shared definition exists to prevent.
enum RecoveryIndexing {
    /// Slot letters in board order; slot `A` is the first candidate.
    static let slotLetters: [String] = Array("ABCDEFGH").map(String.init)

    /// `count` indices spread evenly across `range`, first and last
    /// included, rounded to the nearest index and de-duplicated in order.
    static func evenlySampledIndices(count: Int, range: Range<Int>) -> [Int] {
        guard count > 0, !range.isEmpty else { return [] }
        if count == 1 { return [range.lowerBound] }
        return (0..<count).map { offset in
            range.lowerBound + Int((Double(range.count - 1) * Double(offset) / Double(count - 1)).rounded())
        }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// The open interval between the leader's sampled neighbors, which the
    /// next narrowing pass searches. A leader that is not among the samples
    /// gets a fixed ±4 window.
    static func neighborInterval(around leader: Int, samples: [Int], lowerBound: Int, upperBound: Int) -> Range<Int> {
        guard let position = samples.firstIndex(of: leader) else {
            return max(lowerBound, leader - 4)..<min(upperBound, leader + 5)
        }
        let lower = position > 0 ? samples[position - 1] : lowerBound
        let upper = position + 1 < samples.count ? samples[position + 1] + 1 : upperBound
        return lower..<max(lower + 1, min(upperBound, upper))
    }

    static func stepID(forIndex index: Int, plan: InstructionPlan) -> String {
        index == -1 ? plan.stepZeroID : plan.steps[index].id
    }

    /// The candidate index a slot letter names, or nil for a letter outside
    /// the candidates actually shown.
    static func candidateIndex(forSlot slot: String?, candidates: [Int]) -> Int? {
        guard let slot, let ascii = slot.uppercased().utf8.first else { return nil }
        let offset = Int(ascii) - 65
        return candidates.indices.contains(offset) ? candidates[offset] : nil
    }
}
