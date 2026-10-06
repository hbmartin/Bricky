import AVFoundation
import Foundation

/// Speaks step changes and repairs while hands-free is on (M2.8,
/// ADR 0016). AVFoundation speech synthesis: there is no newer
/// text-to-speech API for apps (apple-speech guide §1.1, ✅ VERIFIED from
/// an Apple staff reply, forum thread 834149).
@MainActor
final class StepNarrator: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    /// Called before the first sound and after the last, so the
    /// microphone gate closes around every sentence.
    var onSpeakingChanged: ((Bool) -> Void)?
    private(set) var lastSpoken: String?
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance playing now. A cancelled one reports after its
    /// replacement has started, and must not reopen the gate.
    private var current: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        lastSpoken = text
        let utterance = AVSpeechUtterance(string: text)
        current = ObjectIdentifier(utterance)
        setSpeaking(true)
        // A newer sentence replaces one still playing: the build moved on.
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        synthesizer.speak(utterance)
    }

    func repeatLast() {
        if let lastSpoken { speak(lastSpoken) }
    }

    func stop() {
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        setSpeaking(false)
    }

    private func ended(_ utterance: ObjectIdentifier) {
        guard utterance == current else { return }
        current = nil
        setSpeaking(false)
    }

    private func setSpeaking(_ speaking: Bool) {
        guard speaking != isSpeaking else { return }
        isSpeaking = speaking
        onSpeakingChanged?(speaking)
    }
}

extension StepNarrator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }
}

/// The sentences hands-free mode speaks, from the String Catalog. The
/// repair sentences themselves come from `RepairPhrasebook`.
enum StepNarration {
    /// "Step 4 of 12. Add the red Brick 2 x 4." One part is named; several
    /// are counted, since a spoken list of part names is hard to follow.
    static func announcement(stepNumber: Int, stepCount: Int, partLabels: [String]) -> String {
        let heading = String(localized: "Step \(stepNumber) of \(stepCount).")
        switch partLabels.count {
        case 0:
            return heading
        case 1:
            return heading + " " + String(localized: "Add the \(partLabels[0]).")
        default:
            return heading + " " + String(localized: "Add \(partLabels.count) parts.")
        }
    }

    /// Why "next" held, and how to go on regardless.
    static func hold(repairSentence: String?) -> String {
        let reason = repairSentence ?? String(localized: "This step doesn't look complete yet.")
        return reason + " " + String(localized: "Say “next anyway” to go on.")
    }

    static func refusal(_ reason: AdvanceRefusal) -> String {
        switch reason {
        case .finished: String(localized: "That was the last step.")
        case .unattended, .noSession: String(localized: "Open the build guide to go on.")
        }
    }

    static var buildFinished: String { String(localized: "That was the last step. The build is done.") }
}
