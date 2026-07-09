import AVFoundation
import Foundation
import Speech

/// Live on-device speech-to-text for the "describe a set out loud" flow.
///
/// Wraps `SFSpeechRecognizer` + `AVAudioEngine`. Publishes a running transcript
/// while recording. Prefers on-device recognition when the locale supports it,
/// so dictation works offline and privately. Reports honest, actionable errors
/// (permissions, availability) and never fabricates text.
@MainActor
final class SpeechDictationService: NSObject, ObservableObject {

    @Published private(set) var transcript: String = ""
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Whether speech recognition is usable on this device/locale right now.
    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    // MARK: - Authorization

    /// Requests speech + microphone permission. Returns `true` only when both
    /// are granted.
    func requestAuthorization() async -> Bool {
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Recording

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording else { return }
        errorMessage = nil

        Task { @MainActor in
            guard await requestAuthorization() else {
                self.errorMessage = "Microphone and Speech access are needed to dictate. Enable them in Settings."
                return
            }
            guard let recognizer, recognizer.isAvailable else {
                self.errorMessage = "Speech recognition isn't available right now."
                return
            }
            do {
                try self.beginSession(with: recognizer)
                self.isRecording = true
            } catch {
                self.errorMessage = "Couldn't start dictation. Please try again."
                self.cleanup()
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isRecording = false
    }

    /// Clears the transcript (e.g. when the user wants to re-dictate).
    func reset() {
        transcript = ""
    }

    // MARK: - Internals

    private func beginSession(with recognizer: SFSpeechRecognizer) throws {
        // Tear down any previous task.
        task?.cancel()
        task = nil

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.cleanup()
                }
            }
        }
    }

    private func cleanup() {
        audioEngine.stop()
        if audioEngine.inputNode.numberOfInputs > 0 {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
