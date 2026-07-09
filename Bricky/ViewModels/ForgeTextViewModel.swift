import SwiftUI
import UIKit

/// Drives the **Describe a Set** flow: a natural-language subject (typed or
/// dictated) becomes a buildable brick set, fully on-device via
/// `VoxelShapeLibrary` + `SetForgeEngine`.
///
/// Larger sizes are a Bricky Pro feature; free users can forge the Small size.
/// Reports honest state and never fabricates a result.
@MainActor
final class ForgeTextViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case generating(percent: Int)
        case completed
        case failed(String)
    }

    // MARK: - Inputs

    @Published var description: String = ""
    @Published var selectedSize: VoxelModel.Size = .small
    /// Optional primary-colour override for the generated model.
    @Published var accentColor: LegoColor?

    // MARK: - Outputs

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: GeneratedLegoSet?
    /// Which template the description matched (honest disclosure to the user).
    @Published private(set) var matchedTemplateName: String?

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

    var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canGenerate: Bool {
        guard trimmedDescription.count >= 2 else { return false }
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
        guard canGenerate else { return }
        let subject = trimmedDescription
        let size = selectedSize
        let accent = accentColor

        task?.cancel()
        result = nil
        matchedTemplateName = nil
        phase = .generating(percent: 5)

        task = Task { [weak self] in
            await self?.run(subject: subject, size: size, accent: accent)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func reset() {
        cancel()
        result = nil
        matchedTemplateName = nil
        phase = .idle
    }

    private func run(subject: String, size: VoxelModel.Size, accent: LegoColor?) async {
        do {
            let generated: (name: String, set: GeneratedLegoSet) = try await Task.detached(priority: .userInitiated) {
                let match = VoxelShapeLibrary.match(for: subject, size: size, accent: accent)
                let name = subject.isEmpty ? match.templateName : subject.capitalizedFirst
                let set = try SetForgeEngine.shared.generate(
                    from: match.model,
                    size: size,
                    name: name
                ) { fraction in
                    Task { @MainActor [weak self] in
                        self?.applyProgress(fraction)
                    }
                }
                return (match.templateName, set)
            }.value

            if Task.isCancelled { return }
            matchedTemplateName = generated.name
            result = generated.set
            phase = .completed
            GeneratedSetStore.shared.save(generated.set)
        } catch {
            if Task.isCancelled { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func applyProgress(_ fraction: Double) {
        guard case .generating = phase else { return }
        phase = .generating(percent: Int((fraction * 100).rounded()))
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
