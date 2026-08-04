import Foundation

/// Reads an unzipped evidence bundle. Kept in the kit (not the CLI) so
/// bundle validation is testable without model weights.
public struct EvidenceBundleReader {
    public struct Session: Sendable {
        public let directory: URL
        public let file: EvidenceSessionFile
        public let traceRows: [EvidenceTraceRow]
    }

    public let bundleDirectory: URL
    public let manifest: EvidenceBundleManifest

    public init(bundleDirectory: URL) throws {
        self.bundleDirectory = bundleDirectory
        let manifestURL = bundleDirectory.appendingPathComponent("evidence_bundle.json")
        manifest = try EvidenceSchema.decoder().decode(
            EvidenceBundleManifest.self,
            from: Data(contentsOf: manifestURL)
        )
    }

    public var sessionsDirectory: URL {
        bundleDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    public func loadSessions() throws -> [Session] {
        let decoder = EvidenceSchema.decoder()
        let directories = try FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        return try directories
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { directory in
                let file = try decoder.decode(
                    EvidenceSessionFile.self,
                    from: Data(contentsOf: directory.appendingPathComponent("session.json"))
                )
                var rows: [EvidenceTraceRow] = []
                if let data = try? Data(contentsOf: directory.appendingPathComponent("traces.ndjson")) {
                    rows = try data.split(separator: UInt8(ascii: "\n")).map {
                        try decoder.decode(EvidenceTraceRow.self, from: Data($0))
                    }
                }
                return Session(directory: directory, file: file, traceRows: rows)
            }
            .sorted { $0.file.createdAt < $1.file.createdAt }
    }

    /// Structural validation: versions, decodability, and referenced files.
    /// Returns human-readable issues; empty means the bundle is sound.
    public func validate() -> [String] {
        var issues: [String] = []
        if manifest.bundleVersion != EvidenceSchema.bundleVersion {
            issues.append("unsupported bundle_version \(manifest.bundleVersion)")
        }
        let sessions: [Session]
        do {
            sessions = try loadSessions()
        } catch {
            return issues + ["sessions unreadable: \(error)"]
        }
        if sessions.isEmpty {
            issues.append("bundle contains no sessions")
        }
        let fileManager = FileManager.default
        for session in sessions {
            let name = session.file.sessionID.uuidString
            if session.file.sessionVersion != EvidenceSchema.sessionVersion {
                issues.append("\(name): unsupported session_version \(session.file.sessionVersion)")
            }
            for row in session.traceRows {
                if row.traceVersion != EvidenceSchema.traceVersion {
                    issues.append("\(name): unsupported trace_version \(row.traceVersion)")
                }
                let board = session.directory.appendingPathComponent(row.boardRelativePath)
                if !fileManager.fileExists(atPath: board.path) {
                    issues.append("\(name): missing board \(row.boardRelativePath)")
                }
                for tile in row.tileRelativePaths.values
                where !fileManager.fileExists(atPath: session.directory.appendingPathComponent(tile).path) {
                    issues.append("\(name): missing tile \(tile)")
                }
            }
            for capture in session.file.captures {
                let url = session.directory.appendingPathComponent(capture.imageRelativePath)
                if !fileManager.fileExists(atPath: url.path) {
                    issues.append("\(name): missing capture \(capture.imageRelativePath)")
                }
            }
        }
        return issues
    }
}
