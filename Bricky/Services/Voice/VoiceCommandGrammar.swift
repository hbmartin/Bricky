import Foundation

/// The few things the build guide answers to by voice (M2.8, ADR 0016).
enum VoiceCommand: String, Sendable, CaseIterable {
    case next
    case nextAnyway = "next_anyway"
    case back
    case repeatLast = "repeat"
}

/// Maps a transcript to a command. Only a finalized result whose whole
/// utterance is a command phrase counts: "next week", "what's next" and a
/// volatile "next" that may still be revised never act.
enum VoiceCommandGrammar {
    static let phrases: [String: VoiceCommand] = [
        "next": .next,
        "next step": .next,
        "next anyway": .nextAnyway,
        "back": .back,
        "go back": .back,
        "previous step": .back,
        "repeat": .repeatLast,
        "say again": .repeatLast,
        "say that again": .repeatLast,
    ]

    /// Biases the transcriber toward the command phrases
    /// (`AnalysisContext.contextualStrings`).
    static var contextualStrings: [String] { phrases.keys.sorted() }

    static func command(for transcript: String, isFinal: Bool) -> VoiceCommand? {
        guard isFinal else { return nil }
        return phrases[normalized(transcript)]
    }

    /// Lowercased letters and digits, with every run of anything else
    /// (punctuation, apostrophes, spaces) collapsed to one space.
    static func normalized(_ transcript: String) -> String {
        transcript.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .joined(separator: " ")
    }
}

/// Keeps the app from hearing itself: closed while narration plays and for
/// `tail` after it ends, so the end of a sentence still in the room never
/// reaches the transcriber (ADR 0016).
struct MicGate: Sendable, Equatable {
    static let tail: TimeInterval = 0.6

    private(set) var speaking = false
    private(set) var reopensAt: TimeInterval = -.infinity

    mutating func narrationStarted() {
        speaking = true
    }

    mutating func narrationEnded(at time: TimeInterval) {
        speaking = false
        reopensAt = time + Self.tail
    }

    func isOpen(at time: TimeInterval) -> Bool {
        !speaking && time >= reopensAt
    }
}
