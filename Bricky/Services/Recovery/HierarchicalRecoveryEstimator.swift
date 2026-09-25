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
    /// Present only when the developer evidence toggle is on; recording is a
    /// pure observer and must never change the estimate.
    private let recorder: RecoveryEvidenceRecorder?
    /// The VLM-path variant this estimate runs (ADR 0010 amendment): vote
    /// rule, decoder feeding, slot uniqueness. Recorded on every trace.
    private let variant: RecoveryInferenceVariant

    init(
        runtime: MLXRecoveryRuntime,
        modelDirectory: URL,
        partPackRoot: URL,
        recorder: RecoveryEvidenceRecorder? = nil,
        variant: RecoveryInferenceVariant = .baseline
    ) {
        self.runtime = runtime
        self.modelDirectory = modelDirectory
        self.partPackRoot = partPackRoot
        self.recorder = recorder
        self.variant = variant
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
        let broad = RecoveryIndexing.evenlySampledIndices(count: min(8, model.steps.count + 1), range: -1..<model.steps.count)
        let centerCapture = captures.first(where: { $0.angle == .center }) ?? captures[1]
        let broadRank = try await rank(capture: centerCapture, indices: broad, plan: model, alignment: alignment, renderer: renderer, pass: .broad, passIndex: 0)
        guard broadRank.status == "matched", let broadLeader = RecoveryIndexing.candidateIndex(forSlot: broadRank.ranking.first, candidates: broad) else {
            return insufficient(captures: captures, started: started, cause: .broadPassUnmatched)
        }

        // Iteratively narrow the leader's neighbor interval until candidate
        // spacing reaches 1, so the true step cannot be structurally excluded
        // from the finalists. Each pass shrinks the interval geometrically;
        // the pass count is log-bounded for safety.
        var interval = RecoveryIndexing.neighborInterval(around: broadLeader, samples: broad, lowerBound: -1, upperBound: model.steps.count)
        var passes = 0
        let maxPasses = max(1, Int(log2(Double(model.steps.count + 2)).rounded(.up)))
        while interval.count > 8, passes < maxPasses {
            try Task.checkCancellation()
            let sampled = RecoveryIndexing.evenlySampledIndices(count: 8, range: interval)
            let passRank = try await rank(capture: centerCapture, indices: sampled, plan: model, alignment: alignment, renderer: renderer, pass: .narrowing, passIndex: passes)
            guard passRank.status == "matched", let passLeader = RecoveryIndexing.candidateIndex(forSlot: passRank.ranking.first, candidates: sampled) else {
                return insufficient(captures: captures, started: started, cause: .narrowingPassUnmatched)
            }
            let next = RecoveryIndexing.neighborInterval(around: passLeader, samples: sampled, lowerBound: -1, upperBound: model.steps.count)
            guard next.count < interval.count else { break }
            interval = next
            passes += 1
        }
        // Once interval.count <= 8, this samples every index (spacing == 1).
        let narrowed = RecoveryIndexing.evenlySampledIndices(count: min(8, interval.count), range: interval)
        let narrowRank = try await rank(capture: centerCapture, indices: narrowed, plan: model, alignment: alignment, renderer: renderer, pass: .narrow, passIndex: 0)
        guard narrowRank.status == "matched", let narrowLeader = RecoveryIndexing.candidateIndex(forSlot: narrowRank.ranking.first, candidates: narrowed) else {
            return insufficient(captures: captures, started: started, cause: .finalPassUnmatched)
        }

        let finalists = Array(Set([narrowLeader - 1, narrowLeader, narrowLeader + 1]))
            .filter { $0 >= -1 && $0 < model.steps.count }
            .sorted()
        let slotMap = Dictionary(uniqueKeysWithValues: zip(RecoveryIndexing.slotLetters, finalists))
        var views: [RecoveryVoteView<Int>] = []
        for (viewIndex, capture) in captures.sorted(by: { $0.angle.rawValue < $1.angle.rawValue }).enumerated() {
            try Task.checkCancellation()
            let result = try await rank(capture: capture, indices: finalists, plan: model, alignment: alignment, renderer: renderer, pass: .finalist, passIndex: viewIndex)
            // Views the model marked insufficient must not vote in scoring
            // or certainty.
            guard result.status == "matched" else { continue }
            views.append(RecoveryVoteView(ranking: result.ranking.map { $0.uppercased() }, candidateForSlot: slotMap))
        }
        guard let vote = RecoveryVote.aggregate(views: views, finalists: finalists, rule: variant.vote) else {
            return insufficient(captures: captures, started: started, cause: .finalistQuorumNotReached)
        }
        let duration = started.duration(to: .now)
        return RecoveryEstimate(
            rankedStepIDs: vote.ordered.prefix(3).map { RecoveryIndexing.stepID(forIndex: $0, plan: model) },
            certainty: vote.certainty,
            modelRevision: RecoveryModelManager.revision,
            latencyMilliseconds: Self.milliseconds(duration),
            captureIDs: captures.map(\.id),
            insufficiencyCause: nil,
            method: .vlm
        )
    }

    private func rank(
        capture: RecoveryCapture,
        indices: [Int],
        plan: InstructionPlan,
        alignment: ARAlignment,
        renderer: InstructionSnapshotRenderer,
        pass: RecoveryPassKind,
        passIndex: Int
    ) async throws -> MLXRankOutput {
        let slots = RecoveryIndexing.slotLetters
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
        let response = try await runtime.rankWithTrace(
            imageURL: board,
            prompt: prompt,
            candidateCount: candidates.count,
            modelDirectory: modelDirectory,
            decode: variant.decode,
            uniqueSlots: variant.uniqueSlots
        )
        if let recorder {
            // Runs before the defer removes the board, so the recorder can
            // copy the exact image the model saw.
            let recorded = zip(candidates, indices).map { candidate, index in
                RecoveryEvidenceRecorder.RecordedCandidate(
                    slot: candidate.slot,
                    stepIndex: index,
                    stepID: RecoveryIndexing.stepID(forIndex: index, plan: plan),
                    jpegData: candidate.image.jpegData(compressionQuality: 0.9)
                )
            }
            await recorder.recordPass(
                pass: pass,
                passIndex: passIndex,
                capture: capture,
                candidates: recorded,
                boardURL: board,
                prompt: prompt,
                trace: response.trace,
                variant: variant
            )
        }
        guard let output = response.output else { throw MLXRecoveryError.invalidStructuredOutput }
        return output
    }

    private func insufficient(captures: [RecoveryCapture], started: ContinuousClock.Instant, cause: RecoveryInsufficiencyCause) -> RecoveryEstimate {
        RecoveryEstimate(
            rankedStepIDs: [],
            certainty: .insufficient,
            modelRevision: RecoveryModelManager.revision,
            latencyMilliseconds: Self.milliseconds(started.duration(to: .now)),
            captureIDs: captures.map(\.id),
            insufficiencyCause: cause,
            method: .vlm
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
