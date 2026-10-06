import Foundation

/// Shadow advisor runs beside photo checks (ADR 0018): each is appended to
/// `shadow-checks.ndjson` as it finishes, and finalize turns labeled ones
/// into `shadow_check` rows. Best-effort, like every recorder write: a lost
/// shadow costs one row, never the check.
extension RecoveryEvidenceRecorder {
    func recordShadowCheck(_ trace: ShadowCheckTraceV1) {
        perform("record shadow check") {
            try ensureStarted()
            var line = try EvidenceSchema.encoder().encode(trace)
            line.append(UInt8(ascii: "\n"))
            try append(line, to: ShadowCheckTraceV1.filename)
        }
    }

    /// Shadow runs written so far.
    func loadShadowCheckTraces() -> [ShadowCheckTraceV1] {
        guard let data = try? Data(contentsOf: sessionDirectory.appendingPathComponent(ShadowCheckTraceV1.filename)) else {
            return []
        }
        let decoder = EvidenceSchema.decoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(ShadowCheckTraceV1.self, from: Data($0)) }
    }

    /// One `shadow_check` row per shadow run in a labeled session.
    func writeShadowCheckRows() throws {
        let rows = ShadowCheckRowV1.deviceRows(session: session, shadows: loadShadowCheckTraces())
        guard !rows.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for row in rows {
            data.append(try encoder.encode(row))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: sessionDirectory.appendingPathComponent(ShadowCheckRowV1.filename), options: .atomic)
    }
}
