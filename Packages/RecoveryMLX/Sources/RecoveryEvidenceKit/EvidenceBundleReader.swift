import Foundation

/// Reads an unzipped evidence bundle. Kept in the kit (not the CLI) so
/// bundle validation is testable without model weights.
public struct EvidenceBundleReader {
    public struct Session: Sendable {
        public let directory: URL
        public let file: EvidenceSessionFile
        public let traceRows: [EvidenceTraceRow]
        /// Geometric candidate fits (ADR 0010). Empty for sessions whose
        /// recovery never ran a geometric pass, and for sessions recorded
        /// before `fits.ndjson` existed — the file is optional, but must
        /// parse when present.
        public let fitRecords: [GeometricFitRecord]
        /// Retained LiDAR observations, one per `depth/<capture-id>.json`.
        public let depthFrames: [EvidenceDepthFrameRecord]
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
                var fits: [GeometricFitRecord] = []
                if let data = try? Data(contentsOf: directory.appendingPathComponent("fits.ndjson")) {
                    fits = try data.split(separator: UInt8(ascii: "\n")).map {
                        try decoder.decode(GeometricFitRecord.self, from: Data($0))
                    }
                }
                var depthFrames: [EvidenceDepthFrameRecord] = []
                let depthDirectory = directory.appendingPathComponent("depth", isDirectory: true)
                let depthSidecars = (try? FileManager.default.contentsOfDirectory(
                    at: depthDirectory, includingPropertiesForKeys: nil
                )) ?? []
                for url in depthSidecars.filter({ $0.pathExtension == "json" }).sorted(by: {
                    $0.lastPathComponent < $1.lastPathComponent
                }) {
                    depthFrames.append(try decoder.decode(
                        EvidenceDepthFrameRecord.self, from: Data(contentsOf: url)
                    ))
                }
                return Session(
                    directory: directory,
                    file: file,
                    traceRows: rows,
                    fitRecords: fits,
                    depthFrames: depthFrames
                )
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
            for record in session.fitRecords {
                if record.fitVersion != EvidenceSchema.fitVersion {
                    issues.append("\(name): unsupported fit_version \(record.fitVersion)")
                }
                // A fit that names some other session would replay against the
                // wrong captures; ownership is part of the contract.
                if record.sessionID != session.file.sessionID {
                    issues.append(
                        "\(name): fit \(record.fitID) belongs to session \(record.sessionID), not this one"
                    )
                }
                // A pose that cannot be reshaped to 4x4 makes the fit
                // unreplayable, which is the whole reason the row is kept.
                if record.worldFromModel.count != 16 {
                    issues.append(
                        "\(name): fit \(record.fitID) has \(record.worldFromModel.count) pose values, expected 16"
                    )
                }
            }
            let captureIDs = Set(session.file.captures.map(\.captureID))
            for frame in session.depthFrames {
                if frame.depthVersion != EvidenceSchema.depthVersion {
                    issues.append("\(name): unsupported depth_version \(frame.depthVersion)")
                }
                // A depth frame is only usable through the capture it observed;
                // one referencing no capture in this session is orphaned data.
                if !captureIDs.contains(frame.captureID) {
                    issues.append(
                        "\(name): depth frame \(frame.captureID) references no capture in this session"
                    )
                }
                if frame.depthIntrinsics.count != 9 {
                    issues.append(
                        "\(name): depth frame \(frame.captureID) has \(frame.depthIntrinsics.count) intrinsics values, expected 9"
                    )
                }
                if frame.worldFromCamera.count != 16 {
                    issues.append(
                        "\(name): depth frame \(frame.captureID) has \(frame.worldFromCamera.count) pose values, expected 16"
                    )
                }
                // Dimensions are judged before plane sizes: a zero, negative,
                // or overflowing width x height makes every byte count
                // meaningless (and 0 x N would let an empty plane pass).
                guard frame.width > 0, frame.height > 0 else {
                    issues.append(
                        "\(name): depth frame \(frame.captureID) has non-positive dimensions \(frame.width)x\(frame.height)"
                    )
                    continue
                }
                // A truncated plane reshapes into silently wrong geometry, so
                // size is checked rather than mere existence — the failure this
                // whole harness exists to stop being invisible.
                for (path, elementSize) in [
                    (frame.depthRelativePath, MemoryLayout<Float32>.size),
                    (frame.confidenceRelativePath, MemoryLayout<UInt8>.size),
                    (frame.rawDepthRelativePath, MemoryLayout<Float32>.size),
                    (frame.rawConfidenceRelativePath, MemoryLayout<UInt8>.size),
                ] {
                    guard let path else { continue }
                    let url = session.directory.appendingPathComponent(path)
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                          let size = values.fileSize else {
                        issues.append("\(name): missing depth plane \(path)")
                        continue
                    }
                    guard let expected = frame.expectedBytes(elementSize: elementSize) else {
                        issues.append(
                            "\(name): depth frame \(frame.captureID) dimensions \(frame.width)x\(frame.height) overflow"
                        )
                        continue
                    }
                    if size != expected {
                        issues.append("\(name): depth plane \(path) is \(size) bytes, expected \(expected)")
                    }
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
