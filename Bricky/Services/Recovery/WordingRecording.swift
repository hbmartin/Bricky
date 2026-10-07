import Foundation

/// Repair-wording pairs (ADR 0017): with evidence capture on, every finished
/// wording attempt is kept beside the template it would replace, so the
/// blinded preference test runs on the phone's own model output.
extension RecoveryEvidenceRecorder {
    func recordWording(_ record: RepairWordingRecordV1) {
        perform("record repair wording") {
            try ensureStarted()
            var line = try EvidenceSchema.encoder().encode(record)
            line.append(UInt8(ascii: "\n"))
            try append(line, to: RepairWordingRecordV1.filename)
        }
    }
}
