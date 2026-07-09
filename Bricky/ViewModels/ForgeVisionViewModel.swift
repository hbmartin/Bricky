import SwiftUI
import UIKit

/// Drives the **Scan to Set** flow: a photo (picked or taken) of a real-world
/// subject becomes a buildable brick set, fully on-device via `PhotoVoxelizer`
/// + `SetForgeEngine`.
///
/// Larger sizes are a Bricky Pro feature; free users can forge the Small size.
@MainActor
final class ForgeVisionViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case generating(percent: Int)
        case completed
        case failed(String)
    }

    // MARK: - Inputs

    @Published var sourceImage: UIImage?
    @Published var selectedSize: VoxelModel.Size = .small
    @Published var subjectName: String = ""

    // MARK: - Outputs

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: GeneratedLegoSet?

    private let isProProvider: @MainActor () -> Bool
    private var task: Task<Void, Never>?

    init(isProProvider: @escaping @MainActor () -> Bool = { SubscriptionManager.shared.isPro }) {
        self.isProProvider = isProProvider
        if !isProProvider() { selectedSize = .small }
    }

    // MARK: - Derived state

    var isProUser: Bool { isProProvider() }

    func isSizeUnlocked(_ size: VoxelModel.Size) -> Bool {
        isProUser || size == .small
    }

    var canGenerate: Bool {
        guard sourceImage != nil else { return false }
        guard isSizeUnlocked(selectedSize) else { return false }
        if case .generating = phase { return false }
        return true
    }

    var isBusy: Bool {
        if case .generating = phase { return true }
        return false
    }

    var progressFraction: Double {
        switch phase {
        case let .generating(percent): return Double(percent) / 100
        case .completed: return 1
        default: return 0
        }
    }

    var errorMessage: String? {
        if case let .failed(message) = phase { return message }
        return nil
    }

    // MARK: - Actions

    func generate() {
        guard canGenerate, let image = sourceImage else { return }
        let size = selectedSize
        let subject = subjectName.trimmingCharacters(in: .whitespacesAndNewlines)

        task?.cancel()
        result = nil
        phase = .generating(percent: 5)

        task = Task { [weak self] in
            await self?.run(image: image, size: size, subject: subject)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func reset() {
        cancel()
        sourceImage = nil
        result = nil
        subjectName = ""
        phase = .idle
    }

    private func run(image: UIImage, size: VoxelModel.Size, subject: String) async {
        do {
            let set: GeneratedLegoSet = try await Task.detached(priority: .userInitiated) {
                let model = try PhotoVoxelizer.voxelize(
                    image: image,
                    size: size,
                    subject: subject.isEmpty ? "Photo" : subject
                )
                let name = subject.isEmpty ? "My Scan" : subject
                return try SetForgeEngine.shared.generate(from: model, size: size, name: name) { fraction in
                    Task { @MainActor [weak self] in
                        self?.applyProgress(0.3 + fraction * 0.7) // voxelize is ~first 30%
                    }
                }
            }.value

            if Task.isCancelled { return }
            result = set
            phase = .completed
            GeneratedSetStore.shared.save(set)
        } catch {
            if Task.isCancelled { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func applyProgress(_ fraction: Double) {
        guard case .generating = phase else { return }
        phase = .generating(percent: min(100, Int((fraction * 100).rounded())))
    }
}
