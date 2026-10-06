import AVFoundation
import Foundation
import os
import Speech

/// Listens for the guide's few commands while the AR guide is open (M2.8,
/// ADR 0016). On device only: `SpeechAnalyzer` with a
/// `DictationTranscriber`, which runs the system dictation models.
///
/// Audio comes from an `AVAudioEngine` input tap converted by
/// `AnalyzerInputConverter`, not from `CaptureInputSequenceProvider`: the
/// provider builds its own `AVCaptureSession`, and ARKit already runs one.
///
/// Order matters, and getting it wrong fails silently (apple-speech guide
/// §5.5): microphone permission, then assets, then the analyzer's format,
/// then the analyzer, then audio. Only finalized results reach the grammar,
/// and only while the microphone gate is open.
@MainActor
final class VoiceCommandService: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case listening
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle
    var onCommand: ((VoiceCommand) -> Void)?

    private let gate = OSAllocatedUnfairLock(initialState: MicGate())
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    /// Bumped by `stop`, so a start still preparing does not open the mic
    /// after the guide has closed.
    private var generation = 0

    func narrationStarted() {
        gate.withLock { $0.narrationStarted() }
    }

    func narrationEnded() {
        gate.withLock { $0.narrationEnded(at: ProcessInfo.processInfo.systemUptime) }
    }

    func start() async {
        switch state {
        case .preparing, .listening: return
        case .idle, .unavailable: break
        }
        generation += 1
        let started = generation
        state = .preparing
        // Apple's 2026 sample asks for the microphone only. Whether
        // SpeechAnalyzer also needs speech-recognition authorization is
        // unverified (apple-speech guide gap G21): the Phase 1 checklist
        // runs this with Speech Recognition denied.
        guard await AVAudioApplication.requestRecordPermission() else {
            return fail(started, String(localized: "Allow the microphone in Settings to use voice commands."))
        }
        // The grammar is English.
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current),
              locale.language.languageCode == .english else {
            return fail(started, String(localized: "Voice commands are available in English only."))
        }
        let transcriber = Self.makeTranscriber(locale: locale)
        do {
            // Nil means the assets are already installed (✅ apple-speech §5.3).
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            // Nil here would mean assets are still missing (✅ §5.5).
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                return fail(started, String(localized: "Voice commands aren't ready on this iPhone yet."))
            }
            guard started == generation else { return }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let context = AnalysisContext()
            context.contextualStrings[.general] = VoiceCommandGrammar.contextualStrings
            try await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: format)
            guard started == generation else {
                await analyzer.cancelAndFinishNow()
                return
            }

            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
            try audioSession.setActive(true)
            let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let feed = TapFeed(
                converter: AnalyzerInputConverter(analyzerFormat: format), continuation: continuation, gate: gate
            )
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            // 100 ms buffers, the shortest a tap supports.
            try input.installAudioTap(
                onBus: 0, bufferSize: AVAudioFrameCount(inputFormat.sampleRate / 10), format: inputFormat
            ) { buffer, _ in
                feed.feed(buffer)
            }
            engine.prepare()
            try engine.start()

            self.engine = engine
            self.analyzer = analyzer
            self.continuation = continuation
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let command = VoiceCommandGrammar.command(
                            for: String(result.text.characters), isFinal: result.isFinal
                        ) else { continue }
                        self?.deliver(command)
                    }
                } catch {
                    // The results end with the analysis; `analysisTask` reports why.
                }
            }
            analysisTask = Task { [weak self] in
                do {
                    _ = try await analyzer.analyzeSequence(inputs)
                } catch {
                    self?.analysisFailed(started, error)
                }
            }
            state = .listening
        } catch {
            fail(started, String(localized: "Voice commands stopped: \(error.localizedDescription)"))
        }
    }

    /// Stops listening at once. Words still being finalized are dropped on
    /// purpose: the guide is closing, and a late command must not act.
    func stop() {
        generation += 1
        tearDown()
        state = .idle
    }

    /// Short utterances without punctuation (`phrase`), finalized often so
    /// a command acts soon after it is said. No volatile results: only
    /// finalized ones may act. 🟡 How much `.frequentFinalization` shortens
    /// the wait on these models is unmeasured (Phase 1 checklist).
    static func makeTranscriber(locale: Locale) -> DictationTranscriber {
        let preset = DictationTranscriber.Preset.phrase
        return DictationTranscriber(
            locale: locale,
            contentHints: preset.contentHints,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions.union([.frequentFinalization]).subtracting([.volatileResults]),
            attributeOptions: preset.attributeOptions
        )
    }

    private func deliver(_ command: VoiceCommand) {
        // Belt and braces: the tap already feeds silence while the gate is
        // closed, so this only drops a result finalized during narration.
        guard state == .listening,
              gate.withLock({ $0.isOpen(at: ProcessInfo.processInfo.systemUptime) }) else { return }
        onCommand?(command)
    }

    private func analysisFailed(_ started: Int, _ error: Error) {
        guard started == generation else { return }
        tearDown()
        state = .unavailable(String(localized: "Voice commands stopped: \(error.localizedDescription)"))
    }

    private func fail(_ started: Int, _ reason: String) {
        guard started == generation else { return }
        tearDown()
        state = .unavailable(reason)
    }

    private func tearDown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Converts tap buffers to analyzer input, feeding silence while the gate is
/// closed so the time line stays continuous and narration is never heard.
/// Used only from the engine's tap, one buffer at a time.
private final class TapFeed: @unchecked Sendable {
    private let converter: AnalyzerInputConverter
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let gate: OSAllocatedUnfairLock<MicGate>

    init(converter: AnalyzerInputConverter, continuation: AsyncStream<AnalyzerInput>.Continuation, gate: OSAllocatedUnfairLock<MicGate>) {
        self.converter = converter
        self.continuation = continuation
        self.gate = gate
    }

    func feed(_ buffer: AVReadOnlyAudioPCMBuffer) {
        let open = gate.withLock { $0.isOpen(at: ProcessInfo.processInfo.systemUptime) }
        let source = AVAudioPCMBuffer(copying: buffer)
        if !open {
            for channel in UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList) {
                if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
            }
        }
        do {
            // Contiguous live audio: no time-code (✅ apple-speech §6.6).
            for input in try converter.convert(source, at: nil) {
                continuation.yield(input)
            }
        } catch {
            continuation.finish()
        }
    }
}
