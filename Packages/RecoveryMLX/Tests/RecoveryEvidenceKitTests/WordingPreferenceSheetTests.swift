import XCTest
@testable import RecoveryEvidenceKit

/// The blinded sheet: only accepted, changed sentences are rated, each once,
/// and the key alone says which option is the model's.
final class WordingPreferenceSheetTests: XCTestCase {
    private func record(
        _ outcome: String, model: String?, template: String = "Add the red Brick 2 x 4.", at seconds: TimeInterval
    ) -> RepairWordingRecordV1 {
        RepairWordingRecordV1(
            sessionID: UUID(), stepID: "m#3", action: "add", partLabel: "red Brick 2 x 4", partCount: 1,
            direction: nil, studs: nil, turn: nil, template: template, modelSentence: model, outcome: outcome,
            shown: model ?? template, latencyMilliseconds: 900, osBuild: "24A430", deviceModel: "iPhone18,1",
            createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    func testOnlyAcceptedChangedSentencesArePairedOnce() {
        let records = [
            record("accepted", model: "Pop the red Brick 2 x 4 on.", at: 1),
            record("accepted", model: "Pop the red Brick 2 x 4 on.", at: 2),
            record("accepted", model: "Add the red Brick 2 x 4.", at: 3),
            record("rejected_foreign_direction", model: "Add it on the left.", at: 4),
            record("failed_refusal", model: nil, at: 5),
            record("accepted", model: "Now add the red Brick 2 x 4.", at: 6)
        ]
        let (pairs, summary) = WordingPreferenceSheet.pairs(from: records, seed: 7)
        XCTAssertEqual(summary, .init(attempts: 6, accepted: 4, identical: 1, duplicates: 1, pairs: 2))
        for pair in pairs {
            let model = pair.modelOption == "A" ? pair.optionA : pair.optionB
            let other = pair.modelOption == "A" ? pair.optionB : pair.optionA
            XCTAssertEqual(other, "Add the red Brick 2 x 4.")
            XCTAssertTrue(["Pop the red Brick 2 x 4 on.", "Now add the red Brick 2 x 4."].contains(model))
        }
        XCTAssertEqual(WordingPreferenceSheet.pairs(from: records, seed: 7).pairs, pairs, "a seed rebuilds the same sheet")
    }

    func testPlacementIsNotAlwaysTheSameSide() {
        let records = (0..<40).map { record("accepted", model: "Sentence \($0) for the red Brick 2 x 4.", at: TimeInterval($0)) }
        let options = WordingPreferenceSheet.pairs(from: records, seed: 3).pairs.map(\.modelOption)
        XCTAssertTrue(options.contains("A"))
        XCTAssertTrue(options.contains("B"))
    }

    func testTheSheetHidesTheKeyAndQuotesFields() {
        let pairs = WordingPreferenceSheet.pairs(
            from: [record("accepted", model: "Add the \"red\" Brick 2 x 4, please.", at: 1)], seed: 1
        ).pairs
        let sheet = WordingPreferenceSheet.sheetCSV(pairs)
        XCTAssertTrue(sheet.hasPrefix("pair_id,action,option_a,option_b,choice\n"))
        XCTAssertFalse(sheet.contains("model_option"))
        XCTAssertTrue(sheet.contains("\"Add the \"\"red\"\" Brick 2 x 4, please.\""))
        XCTAssertTrue(WordingPreferenceSheet.keyCSV(pairs).hasPrefix("pair_id,model_option,os_build,device_model\n"))
    }
}
