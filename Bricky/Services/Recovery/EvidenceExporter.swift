import Foundation
import ZIPFoundation

/// Reads the on-device evidence store and produces export bundles. The zip is
/// the only egress for evidence (ADR 0007) and is always user-initiated.
enum EvidenceExporter {
    struct SessionSummary: Identifiable, Hashable, Sendable {
        let id: UUID
        let directory: URL
        let createdAt: Date
        let modelTitle: String
        let groundTruthKind: EvidenceGroundTruth.Kind
        let hasBenchmarkRow: Bool
        let hasCheckRows: Bool
        let byteCount: Int64
        /// Writes the recorder could not make, and windows it skipped, so a
        /// session with gaps is flagged before it is exported.
        var recorderWriteFailures = 0
        var windowsSkipped = 0
    }

    /// Above this, AirDrop gets slow enough that an export deserves a
    /// second thought. Decimal, to match the size the button shows.
    static let largeExportBytes: Int64 = 500_000_000

    /// Whether to confirm before exporting this many bytes. Judged on the
    /// staged size, which slightly overstates the zip (JPEGs barely
    /// compress), so it errs early.
    static func asksBeforeExport(byteCount: Int64) -> Bool {
        byteCount > largeExportBytes
    }

    static func storeDirectory(root: URL) -> URL {
        root.appendingPathComponent(RecoveryEvidenceRecorder.directoryName, isDirectory: true)
    }

    static func listSessions(root: URL) -> [SessionSummary] {
        let store = storeDirectory(root: root)
        let decoder = EvidenceSchema.decoder()
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: store,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return directories.compactMap { directory -> SessionSummary? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
                  let session = try? decoder.decode(EvidenceSessionFile.self, from: data) else { return nil }
            return SessionSummary(
                id: session.sessionID,
                directory: directory,
                createdAt: session.createdAt,
                modelTitle: session.modelTitle,
                groundTruthKind: session.groundTruth.kind,
                hasBenchmarkRow: FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("benchmark.ndjson").path
                ),
                hasCheckRows: FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(RecoveryEvidenceRecorder.checkRowsFilename).path
                ),
                byteCount: RecoveryEvidenceRecorder.directorySize(directory),
                recorderWriteFailures: session.recorderHealth?.writeFailures ?? 0,
                windowsSkipped: session.recorderHealth?.windowsSkipped ?? 0
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Stages hard links of the selected sessions plus a manifest, zips the
    /// staging directory, and returns the zip URL for the share sheet.
    static func exportBundle(sessions: [SessionSummary]) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: .now)
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("bricky-evidence-\(stamp)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        let sessionsDirectory = staging.appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let manifest = EvidenceBundleManifest(
            bundleVersion: EvidenceSchema.bundleVersion,
            createdAt: .now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            deviceModel: DeviceIdentity.modelIdentifier,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            modelID: RecoveryModelManager.modelID,
            modelRevision: RecoveryModelManager.revision,
            sessionIDs: sessions.map(\.id),
            osBuild: DeviceIdentity.osBuild,
            gpuArchitecture: DeviceIdentity.gpuArchitecture
        )
        try EvidenceSchema.encoder(prettyPrinted: true)
            .encode(manifest)
            .write(to: staging.appendingPathComponent("evidence_bundle.json"), options: .atomic)

        for session in sessions {
            let destination = sessionsDirectory.appendingPathComponent(session.id.uuidString, isDirectory: true)
            do {
                try fileManager.linkItem(at: session.directory, to: destination)
            } catch {
                // Hard links avoid doubling disk; fall back to a real copy if
                // the volume refuses them.
                try fileManager.copyItem(at: session.directory, to: destination)
            }
        }

        let zipURL = fileManager.temporaryDirectory
            .appendingPathComponent("bricky-evidence-\(stamp).zip")
        try? fileManager.removeItem(at: zipURL)
        try fileManager.zipItem(at: staging, to: zipURL, shouldKeepParent: false)
        return zipURL
    }
}
