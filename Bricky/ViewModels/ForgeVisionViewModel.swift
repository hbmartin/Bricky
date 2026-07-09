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
    private let meshService: SetForgeMeshService?
    private let entitlementProvider: () async -> String?
    private var task: Task<Void, Never>?

    init(
        isProProvider: @escaping @MainActor () -> Bool = { SubscriptionManager.shared.isPro },
        meshService: SetForgeMeshService? = AzureTripoMeshClient(),
        entitlementProvider: @escaping () async -> String? = {
            await SubscriptionManager.shared.recognitionEntitlementToken()
        }
    ) {
        self.isProProvider = isProProvider
        self.meshService = meshService
        self.entitlementProvider = entitlementProvider
    }

    // MARK: - Derived state

    var isProUser: Bool { isProProvider() }

    var canGenerate: Bool {
        guard sourceImage != nil else { return false }
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
        guard canGenerate, isProUser, let image = sourceImage else { return }
        let size = selectedSize
        let subject = subjectName.trimmingCharacters(in: .whitespacesAndNewlines)

        task?.cancel()
        result = nil
        phase = .generating(percent: 5)

        task = Task { [weak self] in
            await self?.run(image: image, size: size, subject: subject)
        }
    }

    /// Generate a set directly from a 3D model file (Object Capture output, a
    /// hosted image/text-to-3D mesh, or a user's own `.usdz`/`.obj`). Shares the
    /// same on-device voxel → brick pipeline via `MeshVoxelizer`.
    func generateFromMesh(url: URL) {
        guard !isBusy, isProUser else { return }
        let size = selectedSize
        let subject = subjectName.trimmingCharacters(in: .whitespacesAndNewlines)

        task?.cancel()
        result = nil
        phase = .generating(percent: 5)

        task = Task { [weak self] in
            await self?.runMesh(url: url, size: size, subject: subject)
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
        let token = await entitlementProvider()
        let name = subject.isEmpty ? "My Scan" : subject

        // Tier 1 — hosted image→3D (developer-only). On any failure, fall back
        // to the on-device photo relief so generation never hard-fails.
        var meshModel: VoxelModel?
        if let meshService, let token, let jpeg = image.jpegData(compressionQuality: 0.85) {
            do {
                let url = try await meshService.generateMesh(
                    imageData: jpeg, mime: "image/jpeg", size: size, entitlementToken: token
                )
                meshModel = try await Task.detached(priority: .userInitiated) {
                    try MeshVoxelizer.voxelize(
                        assetURL: url, size: size, subject: subject.isEmpty ? "Photo" : subject
                    )
                }.value
            } catch {
                meshModel = nil
            }
        }
        if Task.isCancelled { return }

        // Tier 2 — on-device photo relief (if the hosted mesh wasn't produced).
        do {
            let set: GeneratedLegoSet = try await Task.detached(priority: .userInitiated) {
                let model: VoxelModel
                if let meshModel {
                    model = meshModel
                } else {
                    model = try PhotoVoxelizer.voxelize(
                        image: image, size: size, subject: subject.isEmpty ? "Photo" : subject
                    )
                }
                return try SetForgeEngine.shared.generate(from: model, size: size, name: name) { fraction in
                    Task { @MainActor [weak self] in
                        self?.applyProgress(0.3 + fraction * 0.7)
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

    private func runMesh(url: URL, size: VoxelModel.Size, subject: String) async {
        do {
            let set: GeneratedLegoSet = try await Task.detached(priority: .userInitiated) {
                let model = try MeshVoxelizer.voxelize(
                    assetURL: url,
                    size: size,
                    subject: subject.isEmpty ? "3D Model" : subject
                )
                let name = subject.isEmpty ? "My Model" : subject
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