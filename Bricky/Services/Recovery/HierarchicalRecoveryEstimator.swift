import Foundation
import RecoveryMLX
import UIKit

protocol RecoveryEstimating: Sendable {
    func estimate(captures: [RecoveryCapture], model: InstructionPlan, alignment: ARAlignment) async throws -> RecoveryEstimate
}

actor HierarchicalRecoveryEstimator: RecoveryEstimating {
    private let runtime: MLXRecoveryRuntime
    private let modelDirectory: URL
    private let partPackRoot: URL

    init(runtime: MLXRecoveryRuntime, modelDirectory: URL, partPackRoot: URL) {
        self.runtime = runtime
        self.modelDirectory = modelDirectory
        self.partPackRoot = partPackRoot
    }

    func estimate(captures: [RecoveryCapture], model: InstructionPlan, alignment: ARAlignment) async throws -> RecoveryEstimate {
        guard captures.count == 3 else {
            throw RecoveryError.invalidCaptureSet(reason: "Recovery requires exactly three guided views.")
        }
        // `alignment.isTracking` is set once at placement and never updated,
        // so it carries no live signal; the real invariant is that the
        // controller nils the alignment on tracking loss and all captures
        // must share the surviving alignment's identity.
        guard captures.allSatisfy({ $0.alignmentID == alignment.id }) else {
            throw RecoveryError.invalidCaptureSet(reason: "The recovery views no longer share a valid alignment. Re-align and capture them again.")
        }
        let started = ContinuousClock.now
        let renderer = try await InstructionSnapshotRenderer(plan: model, partPackRoot: partPackRoot)
        let broad = Self.evenlySampledIndices(count: min(8, model.steps.count + 1), range: -1..<model.steps.count)
        let centerCapture = captures.first(where: { $0.angle == .center }) ?? captures[1]
        let broadRank = try await rank(capture: centerCapture, indices: broad, plan: model, alignment: alignment, renderer: renderer)
        guard broadRank.status == "matched", let broadLeader = Self.index(for: broadRank.ranking.first, candidates: broad) else {
            return insufficient(captures: captures, started: started)
        }

        // Iteratively narrow the leader's neighbor interval until candidate
        // spacing reaches 1, so the true step cannot be structurally excluded
        // from the finalists. Each pass shrinks the interval geometrically;
        // the pass count is log-bounded for safety.
        var interval = Self.neighborInterval(around: broadLeader, samples: broad, lowerBound: -1, upperBound: model.steps.count)
        var passes = 0
        let maxPasses = max(1, Int(log2(Double(model.steps.count + 2)).rounded(.up)))
        while interval.count > 8, passes < maxPasses {
            try Task.checkCancellation()
            let sampled = Self.evenlySampledIndices(count: 8, range: interval)
            let passRank = try await rank(capture: centerCapture, indices: sampled, plan: model, alignment: alignment, renderer: renderer)
            guard passRank.status == "matched", let passLeader = Self.index(for: passRank.ranking.first, candidates: sampled) else {
                return insufficient(captures: captures, started: started)
            }
            let next = Self.neighborInterval(around: passLeader, samples: sampled, lowerBound: -1, upperBound: model.steps.count)
            guard next.count < interval.count else { break }
            interval = next
            passes += 1
        }
        // Once interval.count <= 8, this samples every index (spacing == 1).
        let narrowed = Self.evenlySampledIndices(count: min(8, interval.count), range: interval)
        let narrowRank = try await rank(capture: centerCapture, indices: narrowed, plan: model, alignment: alignment, renderer: renderer)
        guard narrowRank.status == "matched", let narrowLeader = Self.index(for: narrowRank.ranking.first, candidates: narrowed) else {
            return insufficient(captures: captures, started: started)
        }

        let finalists = Array(Set([narrowLeader - 1, narrowLeader, narrowLeader + 1]))
            .filter { $0 >= -1 && $0 < model.steps.count }
            .sorted()
        var rankings: [[(position: Int, step: Int)]] = []
        for capture in captures.sorted(by: { $0.angle.rawValue < $1.angle.rawValue }) {
            try Task.checkCancellation()
            let result = try await rank(capture: capture, indices: finalists, plan: model, alignment: alignment, renderer: renderer)
            // Views the model marked insufficient must not vote in scoring
            // or certainty.
            guard result.status == "matched" else { continue }
            // Enumerate before dropping out-of-range slots so later
            // candidates keep their true rank positions.
            let mapped = result.ranking.enumerated().compactMap { position, slot -> (position: Int, step: Int)? in
                guard let step = Self.index(for: slot, candidates: finalists) else { return nil }
                return (position, step)
            }
            guard !mapped.isEmpty else { continue }
            rankings.append(mapped)
        }
        guard rankings.count >= 2 else { return insufficient(captures: captures, started: started) }

        var scores: [Int: Int] = [:]
        for ranking in rankings {
            for entry in ranking {
                scores[entry.step, default: 0] += max(0, finalists.count - entry.position)
            }
        }
        let ordered = finalists.sorted {
            let lhs = scores[$0, default: 0], rhs = scores[$1, default: 0]
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        let viewLeaders = rankings.compactMap { $0.first?.step }
        let agreement = Dictionary(grouping: viewLeaders, by: { $0 }).values.map(\.count).max() ?? 0
        let certainty: RecoveryCertainty = agreement >= 3 ? .high : (agreement == 2 ? .medium : .low)
        let duration = started.duration(to: .now)
        return RecoveryEstimate(
            rankedStepIDs: ordered.prefix(3).map { $0 == -1 ? model.stepZeroID : model.steps[$0].id },
            certainty: certainty,
            modelRevision: RecoveryModelManager.revision,
            latencyMilliseconds: Self.milliseconds(duration),
            captureIDs: captures.map(\.id)
        )
    }

    private func rank(
        capture: RecoveryCapture,
        indices: [Int],
        plan: InstructionPlan,
        alignment: ARAlignment,
        renderer: InstructionSnapshotRenderer
    ) async throws -> MLXRankOutput {
        let slots = Array("ABCDEFGH").map(String.init)
        var candidates: [(slot: String, image: UIImage, stepNumber: Int)] = []
        for (slot, index) in zip(slots, indices) {
            candidates.append((
                slot,
                try await renderer.image(forStepIndex: index, capture: capture, alignment: alignment),
                index + 1
            ))
        }
        let root = try InstructionModelImporter.applicationSupportRoot()
        let captureURL = root.appendingPathComponent(capture.imageRelativePath)
        let board = try await RecoveryBoardComposer.compose(physicalViewURL: captureURL, candidates: candidates)
        defer { try? FileManager.default.removeItem(at: board) }
        let prompt = "The large top image is a physical brick build. The labeled renders A–H are cumulative authored instruction steps in one fixed model frame. Rank the closest labels from best to worst. Return insufficient when angle, occlusion, or evidence cannot support a comparison."
        return try await runtime.rank(imageURL: board, prompt: prompt, candidateCount: candidates.count, modelDirectory: modelDirectory)
    }

    private func insufficient(captures: [RecoveryCapture], started: ContinuousClock.Instant) -> RecoveryEstimate {
        RecoveryEstimate(
            rankedStepIDs: [],
            certainty: .insufficient,
            modelRevision: RecoveryModelManager.revision,
            latencyMilliseconds: Self.milliseconds(started.duration(to: .now)),
            captureIDs: captures.map(\.id)
        )
    }

    private static func evenlySampledIndices(count: Int, range: Range<Int>) -> [Int] {
        guard count > 0, !range.isEmpty else { return [] }
        if count == 1 { return [range.lowerBound] }
        return (0..<count).map { offset in
            range.lowerBound + Int((Double(range.count - 1) * Double(offset) / Double(count - 1)).rounded())
        }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private static func neighborInterval(around leader: Int, samples: [Int], lowerBound: Int, upperBound: Int) -> Range<Int> {
        guard let position = samples.firstIndex(of: leader) else {
            return max(lowerBound, leader - 4)..<min(upperBound, leader + 5)
        }
        let lower = position > 0 ? samples[position - 1] : lowerBound
        let upper = position + 1 < samples.count ? samples[position + 1] + 1 : upperBound
        return lower..<max(lower + 1, min(upperBound, upper))
    }

    private static func index(for slot: String?, candidates: [Int]) -> Int? {
        guard let slot, let ascii = slot.uppercased().utf8.first else { return nil }
        let offset = Int(ascii) - 65
        return candidates.indices.contains(offset) ? candidates[offset] : nil
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
