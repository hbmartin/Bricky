import Foundation
import SwiftUI

/// What a photo check needs from a live AR session: the locked model pose,
/// and a way to pause depth verification while the VLM holds the GPU.
@MainActor
protocol RegisteredPoseSource {
    /// The locked registration as an alignment; nil unless locked, because a
    /// refining or ambiguous pose would render the target in the wrong place.
    var lockedAlignment: ARAlignment? { get }
    func suspendVerification()
    func resumeVerification()
}

/// Runs one VLM photo check inside the AR guide. The check starts only
/// under a locked registration, pins that pose for its whole run, and keeps
/// live verification paused until it ends — however it ends. The verdict is
/// advisory (ADR 0008); the view decides what a confirm does.
@MainActor
final class PhotoCheckController: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case finished(StepCheckResult)
        case failed(String)
    }

    typealias Check = @MainActor (ARAlignment) async throws -> StepCheckResult

    @Published private(set) var state: State = .idle

    private var task: Task<Void, Never>?
    private var source: (any RegisteredPoseSource)?
    /// Bumped by `cancel` and `reset`: a check that outlives either must not
    /// publish, and must not resume verification a later check suspended.
    private var generation = 0

    var isChecking: Bool { state == .checking }

    /// Starts a check at the source's locked pose. Returns nil, and changes
    /// nothing, when a check is already running or the pose is not locked.
    @discardableResult
    func start(source: some RegisteredPoseSource, check: @escaping Check) -> Task<Void, Never>? {
        guard state != .checking, let alignment = source.lockedAlignment else { return nil }
        generation += 1
        let runGeneration = generation
        self.source = source
        state = .checking
        source.suspendVerification()
        let task = Task { [weak self] in
            let outcome: Result<StepCheckResult, Error>
            do {
                outcome = .success(try await check(alignment))
            } catch {
                outcome = .failure(error)
            }
            self?.finish(outcome, generation: runGeneration)
        }
        self.task = task
        return task
    }

    /// Shows why a check cannot start, without suspending anything.
    func refuse(_ message: String) {
        guard state != .checking else { return }
        state = .failed(message)
    }

    /// Abandons a running check and resumes verification at once.
    func cancel() {
        task?.cancel()
        endRun()
        state = .idle
    }

    /// Clears a finished or failed verdict.
    func reset() {
        guard state != .checking else { return }
        state = .idle
    }

    private func finish(_ outcome: Result<StepCheckResult, Error>, generation runGeneration: Int) {
        guard runGeneration == generation else { return }
        endRun()
        switch outcome {
        case .success(let result):
            state = .finished(result)
        case .failure(is CancellationError):
            state = .idle
        case .failure(let error):
            state = .failed(error.localizedDescription)
        }
    }

    private func endRun() {
        generation += 1
        task = nil
        source?.resumeVerification()
        source = nil
    }
}
