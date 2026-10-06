import Foundation

/// The blinded preference sheet for repair wording (ADR 0017). From device
/// `wording.ndjson` rows it pairs each accepted model sentence with the
/// template it replaced, places the two A or B at random, and writes a
/// sheet for the rater and a key kept from them.
/// `Tools/RecoveryEvaluation/score_wording_ab.py` unblinds the ratings.
public enum WordingPreferenceSheet {
    public struct Pair: Sendable, Equatable {
        public let pairID: String
        public let action: String
        public let optionA: String
        public let optionB: String
        /// Which option is the model's sentence: "A" or "B".
        public let modelOption: String
        public let osBuild: String
        public let deviceModel: String
    }

    public struct Summary: Sendable, Equatable {
        public var attempts = 0
        public var accepted = 0
        /// Accepted sentences identical to their template: nothing to rate.
        public var identical = 0
        /// Repeats of a (template, sentence) pair already on the sheet.
        public var duplicates = 0
        public var pairs = 0
    }

    /// One pair per distinct accepted (template, model sentence), in a
    /// seeded random order with a seeded A/B placement.
    public static func pairs(from records: [RepairWordingRecordV1], seed: UInt64) -> (pairs: [Pair], summary: Summary) {
        var summary = Summary()
        var seen: Set<String> = []
        var candidates: [RepairWordingRecordV1] = []
        for record in records.sorted(by: { $0.createdAt < $1.createdAt }) {
            summary.attempts += 1
            guard record.outcome == "accepted", let sentence = record.modelSentence else { continue }
            summary.accepted += 1
            guard sentence.trimmingCharacters(in: .whitespaces) != record.template.trimmingCharacters(in: .whitespaces) else {
                summary.identical += 1
                continue
            }
            guard seen.insert(record.template + "\u{0}" + sentence).inserted else {
                summary.duplicates += 1
                continue
            }
            candidates.append(record)
        }
        var generator = SplitMix64(seed: seed)
        candidates.shuffle(using: &generator)
        let pairs = candidates.enumerated().map { index, record -> Pair in
            let modelFirst = generator.next() & 1 == 0
            let sentence = record.modelSentence ?? ""
            return Pair(
                pairID: String(format: "w%03d", index + 1),
                action: record.action,
                optionA: modelFirst ? sentence : record.template,
                optionB: modelFirst ? record.template : sentence,
                modelOption: modelFirst ? "A" : "B",
                osBuild: record.osBuild ?? "",
                deviceModel: record.deviceModel ?? ""
            )
        }
        summary.pairs = pairs.count
        return (pairs, summary)
    }

    /// What the rater sees: no hint which option is the model's.
    public static func sheetCSV(_ pairs: [Pair]) -> String {
        csv(header: ["pair_id", "action", "option_a", "option_b", "choice"], rows: pairs.map {
            [$0.pairID, $0.action, $0.optionA, $0.optionB, ""]
        })
    }

    /// Kept from the rater until the ratings are in.
    public static func keyCSV(_ pairs: [Pair]) -> String {
        csv(header: ["pair_id", "model_option", "os_build", "device_model"], rows: pairs.map {
            [$0.pairID, $0.modelOption, $0.osBuild, $0.deviceModel]
        })
    }

    static func csv(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// RFC 4180: quote fields holding a comma, quote or newline.
    static func field(_ value: String) -> String {
        guard value.contains(where: { ",\"\n\r".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// A small seeded generator, so a sheet can be rebuilt identically.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
