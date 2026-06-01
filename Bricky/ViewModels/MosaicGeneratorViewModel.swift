import SwiftUI
import UIKit

/// Drives the LEGO mosaic generation flow: submit a photo to the backend,
/// poll for progress, then surface the finished artifacts (thumbnail, parts
/// list, downloadable LDraw/PDF).
///
/// All core scanning/inventory features in Bricky are offline-first; mosaic
/// generation is the exception because it requires the backend renderer. When
/// the service is unreachable the view model fails **honestly** with an
/// actionable message — it never fabricates a result.
@MainActor
final class MosaicGeneratorViewModel: ObservableObject {

    /// Explicit lifecycle so the view renders one honest state at a time.
    enum Phase: Equatable {
        case idle
        case submitting
        case processing(percent: Int)
        case completed
        case failed(String)
    }

    /// A downloadable artifact the user can export/share.
    enum ArtifactKind: CaseIterable {
        case ldraw
        case pdf

        var filename: String {
            switch self {
            case .ldraw: return "model.ldr"
            case .pdf: return "instructions.pdf"
            }
        }

        func urlString(in result: MosaicJobResult) -> String {
            switch self {
            case .ldraw: return result.ldrURL
            case .pdf: return result.pdfURL
            }
        }
    }

    // MARK: - Published State

    @Published var sourceImage: UIImage?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var snappedGrid: MosaicJobGrid?
    @Published private(set) var result: MosaicJobResult?
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var partsList: MosaicPartsList?

    /// User-selected target size. Defaults to the medium (48×48) preset.
    @Published var selectedPreset: MosaicGridPreset = .medium

    // MARK: - Dependencies

    private let service: MosaicGenerationService
    private let isProProvider: @MainActor () -> Bool
    private let pollInterval: Duration
    private var pollingTask: Task<Void, Never>?

    init(
        service: MosaicGenerationService = .shared,
        pollInterval: Duration = .seconds(2),
        isProProvider: @escaping @MainActor () -> Bool = { SubscriptionManager.shared.isPro }
    ) {
        self.service = service
        self.pollInterval = pollInterval
        self.isProProvider = isProProvider
    }

    // MARK: - Derived State

    /// Mosaic generation is a Pro feature; free users see an honest upsell.
    var isProUser: Bool { isProProvider() }

    var canGenerate: Bool {
        guard sourceImage != nil else { return false }
        switch phase {
        case .submitting, .processing:
            return false
        default:
            return true
        }
    }

    var isBusy: Bool {
        switch phase {
        case .submitting, .processing:
            return true
        default:
            return false
        }
    }

    var progressFraction: Double {
        switch phase {
        case .submitting:
            return 0.05
        case let .processing(percent):
            return Double(percent) / 100.0
        case .completed:
            return 1.0
        default:
            return 0.0
        }
    }

    var errorMessage: String? {
        if case let .failed(message) = phase { return message }
        return nil
    }

    // MARK: - Actions

    /// Submit the current source image and begin polling for completion.
    func generate() {
        guard let image = sourceImage else { return }
        guard !isBusy else { return }

        cancel()
        result = nil
        thumbnail = nil
        partsList = nil
        snappedGrid = nil
        phase = .submitting

        let preset = selectedPreset
        pollingTask = Task { [weak self] in
            await self?.runGeneration(image: image, preset: preset)
        }
    }

    /// Cancel an in-flight generation and return to idle (preserving any
    /// previously completed result is unnecessary — the user restarted).
    func cancel() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Reset everything back to the initial state.
    func reset() {
        cancel()
        sourceImage = nil
        result = nil
        thumbnail = nil
        partsList = nil
        snappedGrid = nil
        phase = .idle
    }

    // MARK: - Flow

    private func runGeneration(image: UIImage, preset: MosaicGridPreset) async {
        do {
            let creation = try await service.submitJob(
                image: image,
                width: preset.studs,
                height: preset.studs
            )
            if Task.isCancelled { return }
            snappedGrid = creation.grid
            phase = .processing(percent: 0)

            let finished = try await pollUntilDone(jobId: creation.jobId)
            if Task.isCancelled { return }

            switch finished.status {
            case .done:
                try await loadResult(jobId: creation.jobId)
            case .error:
                phase = .failed(finished.message ?? L10n.mosaicErrorServerGeneric)
            default:
                phase = .failed(L10n.mosaicErrorServerGeneric)
            }
        } catch is CancellationError {
            // User cancelled — leave state as-is (cancel() already cleared task).
        } catch let error as MosaicGenerationService.ServiceError {
            if !Task.isCancelled {
                phase = .failed(error.localizedDescription)
            }
        } catch {
            if !Task.isCancelled {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Poll `GET /jobs/{id}` until the job reaches a terminal state.
    private func pollUntilDone(jobId: String) async throws -> MosaicJobProgress {
        while true {
            try Task.checkCancellation()
            let progress = try await service.jobStatus(id: jobId)
            phase = .processing(percent: progress.percent)

            if progress.status == .done || progress.status == .error {
                return progress
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private func loadResult(jobId: String) async throws {
        let jobResult = try await service.jobResult(id: jobId)
        if Task.isCancelled { return }
        result = jobResult

        // Best-effort artifact hydration — a missing thumbnail or parts file
        // must not turn a successful build into a failure.
        thumbnail = try? await service.fetchThumbnail(from: jobResult)
        partsList = try? await service.fetchPartsList(from: jobResult)

        phase = .completed
    }
}

// MARK: - Artifact Export

extension MosaicGeneratorViewModel {

    /// Download an artifact and write it to a temporary file suitable for a
    /// share sheet. Returns `nil` (never a fake file) when there is no result
    /// or the download fails.
    func prepareArtifactFile(kind: ArtifactKind) async -> URL? {
        guard let result else { return nil }
        do {
            let data = try await service.downloadArtifact(at: kind.urlString(in: result))
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mosaic-\(result.jobId)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let fileURL = directory.appendingPathComponent(kind.filename)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }
}