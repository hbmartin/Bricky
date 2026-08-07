import Foundation
import ZIPFoundation

@MainActor
final class LDrawPartPackManager: ObservableObject {
    enum State: Equatable {
        case checking
        case notInstalled
        case downloading(Double)
        case extracting
        case ready
        case failed(String)
    }

    static let version = "2026-07"
    static let archiveBytes: Int64 = 144_722_356
    static let archiveSHA256 = "6009f2e94204c4d3a63a4c812010b5c90bad8c5acb19b882c859fdac63734eae"
    static let downloadURL = URL(string: "https://github.com/hbmartin/Bricky/releases/download/ldraw-2026-07/complete.zip")!
    static let attribution = "LDraw Parts Library 2026-07. Parts are available under CC BY 2.0 and CC BY 4.0; see the bundled attribution notice."

    @Published private(set) var state: State = .checking
    private let downloader = VerifiedAssetDownloader()
    private var isInstalling = false

    var libraryURL: URL? {
        guard let root = try? InstructionModelImporter.applicationSupportRoot() else { return nil }
        return root.appendingPathComponent("PartPacks/\(Self.version)/ldraw", isDirectory: true)
    }

    func checkInstalled() async {
        guard let libraryURL else {
            state = .failed("Application Support is unavailable.")
            return
        }
        let hasParts = FileManager.default.fileExists(atPath: libraryURL.appendingPathComponent("parts").path)
        let marker = try? String(contentsOf: libraryURL.appendingPathComponent("_release.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if hasParts && marker == Self.version {
            // Install the palette before publishing .ready so renderers never
            // draw a ready pack with the fallback colours.
            await installPalette(from: libraryURL)
            state = .ready
        } else {
            state = .notInstalled
        }
    }

    /// Loads `LDConfig.ldr` off the main actor and installs the parsed palette
    /// for every renderer. A missing or unreadable LDConfig leaves the
    /// hardcoded fallback palette in place; it never fails the pack.
    private func installPalette(from libraryURL: URL) async {
        let definitions = await Task.detached(priority: .utility) {
            try? LDConfigPalette.load(libraryURL: libraryURL)
        }.value
        if let definitions, !definitions.isEmpty {
            LDrawPalette.install(definitions)
        }
    }

    func install() async {
        // A second install while one runs would race the same partial and
        // extraction paths; the main actor serializes this flag across awaits.
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let root = try InstructionModelImporter.applicationSupportRoot()
            let packRoot = root.appendingPathComponent("PartPacks/\(Self.version)", isDirectory: true)
            try FileManager.default.createDirectory(at: packRoot, withIntermediateDirectories: true)
            let archiveURL = packRoot.appendingPathComponent("complete.zip")
            state = .downloading(0)
            try await downloader.download(
                from: Self.downloadURL,
                to: archiveURL,
                expectedBytes: Self.archiveBytes,
                expectedSHA256: Self.archiveSHA256
            ) { value in
                await self.updateDownloadProgress(value)
            }
            state = .extracting
            let destination = packRoot.appendingPathComponent("ldraw", isDirectory: true)
            let staging = packRoot.appendingPathComponent("extract-staging-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            do {
                // Extracting ~20k entries is far too slow for the main thread;
                // the nonisolated helper runs on the concurrent executor while
                // state stays on the main actor.
                try await Self.extractArchive(at: archiveURL, into: staging)
                let extractedLibrary = staging.appendingPathComponent("ldraw", isDirectory: true)
                guard FileManager.default.fileExists(atPath: extractedLibrary.appendingPathComponent("parts").path) else {
                    throw InstructionImportError.invalidDocument("The verified archive does not contain a complete LDraw library.")
                }
                try Data((Self.version + "\n").utf8)
                    .write(to: extractedLibrary.appendingPathComponent("_release.txt"), options: .atomic)
                let backup = packRoot.appendingPathComponent("ldraw-backup-\(UUID().uuidString)", isDirectory: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.moveItem(at: destination, to: backup)
                }
                do {
                    try FileManager.default.moveItem(at: extractedLibrary, to: destination)
                    try? FileManager.default.removeItem(at: backup)
                } catch {
                    if !FileManager.default.fileExists(atPath: destination.path),
                       FileManager.default.fileExists(atPath: backup.path) {
                        try? FileManager.default.moveItem(at: backup, to: destination)
                    }
                    throw error
                }
                try? FileManager.default.removeItem(at: staging)
                try? FileManager.default.removeItem(at: archiveURL)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
            if let libraryURL {
                await installPalette(from: libraryURL)
            }
            state = .ready
        } catch is CancellationError {
            state = .notInstalled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func updateDownloadProgress(_ value: Double) {
        state = .downloading(value)
    }

    /// Extracts the verified archive into the staging directory off the main
    /// actor. Every entry keeps the same safety gates: symlinks are rejected
    /// and paths must survive `normalizeReference` (no traversal, no absolutes).
    private nonisolated static func extractArchive(at archiveURL: URL, into staging: URL) async throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        for entry in archive {
            try Task.checkCancellation()
            guard entry.type != .symlink else {
                throw InstructionImportError.unsafePath(entry.path)
            }
            let normalized = try LDrawInstructionParser.normalizeReference(entry.path)
            let output = staging.appendingPathComponent(normalized)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: output)
        }
    }
}
