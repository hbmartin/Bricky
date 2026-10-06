import XCTest
@testable import Bricky

/// Only a finalized utterance that is wholly a command acts (ADR 0016).
final class VoiceCommandGrammarTests: XCTestCase {
    func testCommandsMatchWholeUtterances() {
        XCTAssertEqual(VoiceCommandGrammar.command(for: "next", isFinal: true), .next)
        XCTAssertEqual(VoiceCommandGrammar.command(for: "Next.", isFinal: true), .next)
        XCTAssertEqual(VoiceCommandGrammar.command(for: "  Next step!  ", isFinal: true), .next)
        XCTAssertEqual(VoiceCommandGrammar.command(for: "NEXT, anyway", isFinal: true), .nextAnyway)
        XCTAssertEqual(VoiceCommandGrammar.command(for: "Go back.", isFinal: true), .back)
        XCTAssertEqual(VoiceCommandGrammar.command(for: "say that again?", isFinal: true), .repeatLast)
    }

    func testSentencesContainingACommandWordDoNotAct() {
        for transcript in ["next week", "what's next", "What’s next?", "next next", "back up", "I'm going back", "", "..."] {
            XCTAssertNil(VoiceCommandGrammar.command(for: transcript, isFinal: true), transcript)
        }
    }

    func testVolatileResultsNeverAct() {
        for phrase in VoiceCommandGrammar.phrases.keys {
            XCTAssertNil(VoiceCommandGrammar.command(for: phrase, isFinal: false), phrase)
        }
    }

    func testEveryCommandIsReachableAndBiased() {
        XCTAssertEqual(Set(VoiceCommandGrammar.phrases.values), Set(VoiceCommand.allCases))
        XCTAssertEqual(Set(VoiceCommandGrammar.contextualStrings), Set(VoiceCommandGrammar.phrases.keys))
        for phrase in VoiceCommandGrammar.phrases.keys {
            XCTAssertEqual(VoiceCommandGrammar.normalized(phrase), phrase, "phrases are stored normalized")
        }
    }

    func testTheMicStaysClosedThroughNarrationAndItsTail() {
        var gate = MicGate()
        XCTAssertTrue(gate.isOpen(at: 10))
        gate.narrationStarted()
        XCTAssertFalse(gate.isOpen(at: 10))
        XCTAssertFalse(gate.isOpen(at: 1_000), "closed for as long as narration plays")
        gate.narrationEnded(at: 20)
        XCTAssertFalse(gate.isOpen(at: 20.59))
        XCTAssertTrue(gate.isOpen(at: 20 + MicGate.tail))
        XCTAssertEqual(MicGate.tail, 0.6)
    }

    @MainActor
    func testNarrationNamesOnePartAndCountsSeveral() {
        XCTAssertEqual(
            StepNarration.announcement(stepNumber: 4, stepCount: 12, partLabels: ["red Brick 2 x 4"]),
            "Step 4 of 12. Add the red Brick 2 x 4."
        )
        XCTAssertEqual(
            StepNarration.announcement(stepNumber: 5, stepCount: 12, partLabels: ["a", "b", "c"]),
            "Step 5 of 12. Add 3 parts."
        )
        XCTAssertEqual(StepNarration.announcement(stepNumber: 1, stepCount: 2, partLabels: []), "Step 1 of 2.")
        XCTAssertEqual(
            StepNarration.hold(repairSentence: "Move the red Brick 2 x 4 one stud to your left."),
            "Move the red Brick 2 x 4 one stud to your left. Say “next anyway” to go on."
        )
        XCTAssertEqual(
            StepNarration.hold(repairSentence: nil),
            "This step doesn't look complete yet. Say “next anyway” to go on."
        )
    }
}
