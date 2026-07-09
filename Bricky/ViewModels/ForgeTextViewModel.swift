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
    private let cloudService: SetForgeTextService?
    private let meshService: SetForgeMeshService?
    private let entitlementProvider: () async -> String?
    private var task: Task<Void, Never>?

    init(
        isProProvider: @escaping @MainActor () -> Bool = { SubscriptionManager.shared.isPro },
        cloudService: SetForgeTextService? = AzureOpenAIForgeTextClient(),
        meshService: SetForgeMeshService? = AzureTripoMeshClient(),
        entitlementProvider: @escaping () async -> String? = {
            await SubscriptionManager.shared.recognitionEntitlementToken()
        }
    ) {
        self.isProProvider = isProProvider
        self.cloudService = cloudService
        self.meshService = meshService
        self.entitlementProvider = entitlementProvider
    }

    // MARK: - Derived state

    var isProUser: Bool { isProProvider() }

    var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canGenerate: Bool {
        guard trimmedDescription.count >= 2 else { return false }
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
        guard canGenerate, isProUser else { return }
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
        let token = await entitlementProvider()

        // Cloud tiers (developer-only). Any failure falls through to the next
        // tier, so generation never hard-fails.
        var cloudModel: VoxelModel?
        var label = ""

        // Tier 1 — Tripo HD mesh → voxelize on-device (highest fidelity).
        if let meshService, let token {
            do {
                let url = try await meshService.generateMesh(
                    prompt: subject, size: size, entitlementToken: token
                )
                cloudModel = try await Task.detached(priority: .userInitiated) {
                    try MeshVoxelizer.voxelize(assetURL: url, size: size, subject: subject)
                }.value
                label = "AI 3D"
            } catch {
                cloudModel = nil
            }
        }
        if Task.isCancelled { return }

        // Tier 2 — GPT voxel DSL.
        if cloudModel == nil, let service = cloudService, let token {
            do {
                cloudModel = try await service.generateModel(
                    prompt: subject, size: size, entitlementToken: token
                )
                label = "AI-generated"
            } catch {
                cloudModel = nil
            }
        }
        if Task.isCancelled { return }

        // Tier 3 — on-device shape library.
        let model: VoxelModel
        if let cloudModel {
            model = cloudModel
        } else {
            let match = VoxelShapeLibrary.match(for: subject, size: size, accent: accent)
            model = match.model
            label = match.templateName
        }

        // Build the set on-device.
        do {
            let name = subject.isEmpty ? label : subject.capitalizedFirst
            let generator: GeneratedLegoSet.Generator =
                label == "AI 3D" ? .hd : (label == "AI-generated" ? .ai : .onDevice)
            let set: GeneratedLegoSet = try await Task.detached(priority: .userInitiated) {
                try SetForgeEngine.shared.generate(from: model, size: size, name: name, generator: generator) { fraction in
                    Task { @MainActor [weak self] in
                        self?.applyProgress(fraction)
                    }
                }
            }.value

            if Task.isCancelled { return }
            matchedTemplateName = label
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
        phase = .generating(percent: Int((fraction * 100).rounded()))
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
