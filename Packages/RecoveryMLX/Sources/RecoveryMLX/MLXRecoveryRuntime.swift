import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon
import MLXVLM
import os
import Tokenizers

public struct MLXRankOutput: Codable, Sendable {
    public let status: String
    public let ranking: [String]
}

public struct MLXStepCheckOutput: Codable, Sendable {
    public let result: String
}

public enum MLXRecoveryError: LocalizedError {
    case invalidStructuredOutput
    /// The processor returned no image, so the model would have answered
    /// from the prompt alone. The pinned Qwen3-VL silently falls back to
    /// text-only when its image list is empty; a comparison board the model
    /// never saw must fail loudly instead.
    case imageInputDropped
    case variantRequiresFork(String)

    public var errorDescription: String? {
        switch self {
        case .invalidStructuredOutput: "The on-device model did not produce a valid guided result."
        case .imageInputDropped: "The on-device model received no image for this comparison."
        case .variantRequiresFork(let axis): "The \(axis) variant needs the forked decoder, not decode=upstream."
        }
    }
}

/// One serial, stateless inference lane backed by one ModelContainer.
public actor MLXRecoveryRuntime {
    static let rankSlotLetters = ["A", "B", "C", "D", "E", "F", "G", "H"]

    /// The rank grammar is generated per candidate count so the model can
    /// never emit a slot letter that has no tile on the board. A fixed A–H
    /// enum lets a 3-tile board legally answer "H", which the estimator then
    /// drops without a trace.
    static func rankSchema(slotCount: Int) -> String {
        let count = min(max(slotCount, 1), rankSlotLetters.count)
        let letters = rankSlotLetters.prefix(count).map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"type":"object","properties":{"status":{"type":"string","enum":["matched","insufficient"]},"ranking":{"type":"array","items":{"type":"string","enum":[\#(letters)]},"minItems":1,"maxItems":\#(count),"uniqueItems":true}},"required":["status","ranking"],"additionalProperties":false}"#
    }
    private static let checkSchema = #"{"type":"object","properties":{"result":{"type":"string","enum":["complete","incomplete","uncertain"]}},"required":["result"],"additionalProperties":false}"#

    private static let signposter = OSSignposter(subsystem: "com.bricky.app", category: "Inference")

    /// Bounded Metal buffer cache for iOS. MLX otherwise defaults the cache
    /// limit to the memory limit, which is far too large next to 3 GB of
    /// weights on an iPhone.
    private static let gpuCacheLimitBytes = 20 * 1024 * 1024

    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    private var grammarCache: GrammarCache?
    /// Incremented by `unload()`. A load that finishes after an interleaved
    /// unload must not resurrect the container.
    private var loadGeneration = 0
    private var activeLoadWaiters = 0
    private var isUnloading = false
    /// Concurrent `unload()` callers parked until the primary unload finishes.
    private var unloadWaiters: [CheckedContinuation<Void, Never>] = []
    /// The primary unload parked until every load waiter drops its result.
    private var loadDrainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Where the loaded container is in its life, for the cold/warm bucket.
    private var loadStartedAt: ContinuousClock.Instant?
    private var loadedAt: ContinuousClock.Instant?
    private var loadMilliseconds: Int?
    private var callsSinceLoad = 0

    public init() {}

    public func load(modelDirectory: URL) async throws {
        _ = try await modelContainer(modelDirectory: modelDirectory)
    }

    /// Headroom over the worst-case 8-slot ranking (~64 tokens under the
    /// grammar). Bricky passes no closing bias, so no soft zone exists; with
    /// the shim's `any_whitespace = true`, only a whitespace run can exhaust
    /// the budget. Generation halts at grammar acceptance, so the common case
    /// pays nothing.
    static let rankMaxTokens = 192
    static let checkMaxTokens = 48

    public func rank(imageURL: URL, prompt: String, candidateCount: Int, modelDirectory: URL) async throws -> MLXRankOutput {
        let response = try await rankWithTrace(
            imageURL: imageURL,
            prompt: prompt,
            candidateCount: candidateCount,
            modelDirectory: modelDirectory
        )
        guard let output = response.output else { throw MLXRecoveryError.invalidStructuredOutput }
        return output
    }

    /// `maxTokens` and `decode` are A/B knobs for the Mac harness; the app
    /// passes the defaults.
    public func rankWithTrace(
        imageURL: URL,
        prompt: String,
        candidateCount: Int,
        modelDirectory: URL,
        maxTokens: Int? = nil,
        decode: DecodeMode = .legacy,
        uniqueSlots: Bool = false
    ) async throws -> MLXRankResponse {
        let generated = try await generate(
            imageURL: imageURL,
            prompt: prompt,
            kind: .rank(slotCount: candidateCount),
            modelDirectory: modelDirectory,
            maxTokens: maxTokens ?? Self.rankMaxTokens,
            decode: decode,
            uniqueSlots: uniqueSlots
        )
        var output: MLXRankOutput?
        var decodeError: String?
        do {
            output = try JSONDecoder().decode(MLXRankOutput.self, from: Data(generated.text.utf8))
        } catch {
            decodeError = String(describing: error)
        }
        return MLXRankResponse(
            output: output,
            trace: generated.trace(decodeError: decodeError, schemaJSON: Self.rankSchema(slotCount: candidateCount))
        )
    }

    public func checkStep(imageURL: URL, prompt: String, modelDirectory: URL) async throws -> MLXStepCheckOutput {
        let response = try await checkStepWithTrace(imageURL: imageURL, prompt: prompt, modelDirectory: modelDirectory)
        guard let output = response.output else { throw MLXRecoveryError.invalidStructuredOutput }
        return output
    }

    public func checkStepWithTrace(
        imageURL: URL,
        prompt: String,
        modelDirectory: URL,
        decode: DecodeMode = .legacy
    ) async throws -> MLXCheckResponse {
        let generated = try await generate(
            imageURL: imageURL,
            prompt: prompt,
            kind: .check,
            modelDirectory: modelDirectory,
            maxTokens: Self.checkMaxTokens,
            decode: decode,
            uniqueSlots: false
        )
        var output: MLXStepCheckOutput?
        var decodeError: String?
        do {
            output = try JSONDecoder().decode(MLXStepCheckOutput.self, from: Data(generated.text.utf8))
        } catch {
            decodeError = String(describing: error)
        }
        return MLXCheckResponse(
            output: output,
            trace: generated.trace(decodeError: decodeError, schemaJSON: Self.checkSchema)
        )
    }

    /// Production-sized fit test. Loading weights alone is not admission.
    public func warmUp(imageURL: URL, modelDirectory: URL) async throws {
        _ = try await checkStep(
            imageURL: imageURL,
            prompt: "Return uncertain. This is a device fit test.",
            modelDirectory: modelDirectory
        )
    }

    public func unload() async {
        if isUnloading {
            await withCheckedContinuation { unloadWaiters.append($0) }
            return
        }
        isUnloading = true
        loadGeneration += 1
        // Nothing loaded means nothing allocated: skip touching the Metal
        // allocator at all (it is also unavailable in the Simulator, where
        // an unconditional clear aborted the process).
        let heldResources = container != nil || loadTask != nil
        var inFlight = loadTask
        // Clear state before suspending so reentrant callers observe the
        // unloading barrier immediately and cannot start replacement loads.
        loadTask = nil
        grammarCache = nil
        container = nil
        loadedAt = nil
        loadStartedAt = nil
        if let inFlight {
            inFlight.cancel()
            // Drain the in-flight load so callers can rely on the weights
            // being released (or the load abandoned) when this returns.
            _ = try? await inFlight.value
        }
        // Completed Task values retain their result. Drop the last local task
        // handle, then let every modelContainer waiter release its own local
        // result before clearing MLX's cache. New waiters cannot appear here:
        // `modelContainer` rejects callers while `isUnloading` is set.
        inFlight = nil
        while activeLoadWaiters > 0 {
            await withCheckedContinuation { loadDrainWaiters.append($0) }
        }
        if heldResources {
            MLX.Memory.clearCache()
        }
        isUnloading = false
        let parked = unloadWaiters
        unloadWaiters = []
        for waiter in parked { waiter.resume() }
    }

    fileprivate enum GrammarKind: Sendable {
        case rank(slotCount: Int)
        case check
    }

    fileprivate struct GeneratedText: Sendable {
        let text: String
        let generatedTokens: Int?
        let termination: MLXGenerationTrace.Termination
        let latencyMilliseconds: Int
        let maxTokens: Int
        var inference: InferenceTelemetry?
        let readouts: [DecisionReadout]?

        func trace(decodeError: String?, schemaJSON: String) -> MLXGenerationTrace {
            MLXGenerationTrace(
                rawOutput: text,
                decodeErrorDescription: decodeError,
                generatedTokens: generatedTokens,
                termination: termination,
                latencyMilliseconds: latencyMilliseconds,
                maxTokens: maxTokens,
                schemaJSON: schemaJSON,
                inference: inference,
                readouts: readouts
            )
        }
    }

    private func generate(
        imageURL: URL,
        prompt: String,
        kind: GrammarKind,
        modelDirectory: URL,
        maxTokens: Int,
        decode: DecodeMode,
        uniqueSlots: Bool
    ) async throws -> GeneratedText {
        // Unique slots needs the forked decoder's mask; the upstream loop
        // cannot apply it.
        if uniqueSlots, decode == .upstream {
            throw MLXRecoveryError.variantRequiresFork("unique_slots")
        }
        try Task.checkCancellation()
        let container = try await modelContainer(modelDirectory: modelDirectory)
        let cache = try await grammarResources(container: container)
        let started = ContinuousClock.now
        var inference = InferenceTelemetry(
            memoryBefore: ProcessMemorySnapshot.current(),
            thermalBefore: ThermalStateName.current,
            callsSinceLoad: callsSinceLoad,
            secondsSinceLoad: loadedAt.map { Self.seconds($0.duration(to: .now)) },
            loadMilliseconds: loadMilliseconds
        )
        callsSinceLoad += 1
        var generated = try await container.perform(values: GenerationValues(
            imageURL: imageURL,
            prompt: prompt,
            kind: kind,
            maxTokens: maxTokens,
            decode: decode,
            uniqueSlotLetters: {
                guard uniqueSlots, case .rank(let slotCount) = kind else { return nil }
                return Set(Self.rankSlotLetters.prefix(min(max(slotCount, 1), Self.rankSlotLetters.count)).compactMap(\.first))
            }(),
            cache: cache
        )) { context, values in
            let signpost = Self.signposter.beginInterval("Generate", id: Self.signposter.makeSignpostID(), "\(values.decode.rawValue)")
            defer { Self.signposter.endInterval("Generate", signpost) }
            var userInput = UserInput(prompt: values.prompt, images: [.url(values.imageURL)])
            userInput.processing = .init(resize: CGSize(width: 1024, height: 1024))
            let preprocessStarted = ContinuousClock.now
            let input = try await context.processor.prepare(input: userInput)
            let preprocessElapsed = preprocessStarted.duration(to: .now).components
            guard input.image != nil else { throw MLXRecoveryError.imageInputDropped }
            // A matcher is stateful, so every stateless call gets a fresh
            // one. It is compiled rather than cloned: the pinned bridge's
            // clone() always throws ("Fork() not available in xgrammar
            // v0.1.30"), and compiling one of these schemas takes ~7 ms
            // once the grammar tokenizer (~0.7 s) is cached.
            let constraint = try values.cache.freshConstraint(for: values.kind, hostTokenizer: context.tokenizer)
            var output = ""
            var generatedTokens: Int?
            var termination = MLXGenerationTrace.Termination.accepted
            var decodeTelemetry: DecodeTelemetry?
            var readouts: [DecisionReadout]?
            let emit: (String) -> Bool = { delta in
                output += delta
                return !Task.isCancelled
            }
            if let feeding = values.decode.feeding {
                let result = try RecoveryGuidedDecoder.run(
                    input: input,
                    context: context,
                    constraint: constraint,
                    maxTokens: values.maxTokens,
                    vocabSize: values.cache.tokenizer.vocabSize,
                    feeding: feeding,
                    uniqueSlotLetters: values.uniqueSlotLetters,
                    emit: emit
                )
                // Same trace semantics as the upstream path below: an
                // exhausted budget reports no token count.
                if result.grammarAccepted {
                    generatedTokens = result.tokenCount
                } else {
                    termination = .maxTokensExhausted
                }
                var measured = result.telemetry
                measured.preprocessMilliseconds = Int(
                    preprocessElapsed.seconds * 1_000 + preprocessElapsed.attoseconds / 1_000_000_000_000_000
                )
                decodeTelemetry = measured
                readouts = result.readouts
            } else {
                do {
                    generatedTokens = try GuidedGenerationLoop.run(
                        input: input,
                        context: context,
                        constraint: constraint,
                        maxTokens: values.maxTokens,
                        vocabSize: values.cache.tokenizer.vocabSize,
                        emit: emit
                    )
                } catch GuidedGenerationError.incompleteOutput {
                    // The partial text is evidence; before this catch it was
                    // destroyed and truncation was unobservable.
                    termination = .maxTokensExhausted
                }
            }
            try Task.checkCancellation()
            let elapsed = started.duration(to: .now).components
            return GeneratedText(
                text: output,
                generatedTokens: generatedTokens,
                termination: termination,
                latencyMilliseconds: Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000),
                maxTokens: values.maxTokens,
                inference: InferenceTelemetry(decode: decodeTelemetry),
                readouts: readouts
            )
        }
        inference.decode = generated.inference?.decode
        inference.memoryAfter = ProcessMemorySnapshot.current()
        inference.thermalAfter = ThermalStateName.current
        generated.inference = inference
        return generated
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func modelContainer(modelDirectory: URL) async throws -> ModelContainer {
        guard !isUnloading else { throw CancellationError() }
        if let container { return container }
        if let loadTask {
            return try await finishLoading(loadTask, generation: loadGeneration)
        }
        // Bound the Metal buffer cache before any weights load.
        MLX.Memory.cacheLimit = Self.gpuCacheLimitBytes
        let generation = loadGeneration
        loadStartedAt = .now
        let task = Task<ModelContainer, Error> {
            try await VLMModelFactory.shared.loadContainer(
                from: try LoadableModelDirectory.resolve(modelDirectory),
                using: TransformersTokenizerLoader()
            )
        }
        loadTask = task
        return try await finishLoading(task, generation: generation)
    }

    private func finishLoading(
        _ task: Task<ModelContainer, Error>,
        generation: Int
    ) async throws -> ModelContainer {
        activeLoadWaiters += 1
        defer {
            // By the time this runs, the waiter's local `loaded` reference is
            // gone (nilled on the unload path, or ownership passed to
            // `container`), so the last waiter out can release the unload.
            activeLoadWaiters -= 1
            if activeLoadWaiters == 0 {
                let parked = loadDrainWaiters
                loadDrainWaiters = []
                for waiter in parked { waiter.resume() }
            }
        }
        do {
            var loaded: ModelContainer? = try await task.value
            guard generation == loadGeneration, !isUnloading else {
                // unload() ran while the weights were loading; do not
                // resurrect a multi-gigabyte container.
                loaded = nil
                throw CancellationError()
            }
            if container == nil, let loadStartedAt {
                loadMilliseconds = Self.milliseconds(loadStartedAt.duration(to: .now))
                loadedAt = .now
                callsSinceLoad = 0
            }
            container = loaded
            if loadTask == task { loadTask = nil }
            return loaded!
        } catch {
            if loadTask == task { loadTask = nil }
            throw error
        }
    }

    private func grammarResources(container: ModelContainer) async throws -> GrammarCache {
        if let grammarCache { return grammarCache }
        let cache = try await container.perform { context in
            let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
            let tokenizer = try GrammarTokenizer(
                vocab: vocab.vocab,
                vocabType: vocab.vocabType,
                eosTokenId: Int32(context.tokenizer.eosTokenId ?? 0)
            )
            let cache = GrammarCache(tokenizer: tokenizer, checkSchema: Self.checkSchema)
            // Compile every schema once so a bad one fails the admission
            // warm-up rather than the first recovery.
            for count in 1...Self.rankSlotLetters.count {
                _ = try cache.freshConstraint(for: .rank(slotCount: count), hostTokenizer: context.tokenizer)
            }
            _ = try cache.freshConstraint(for: .check, hostTokenizer: context.tokenizer)
            return cache
        }
        grammarCache = cache
        return cache
    }
}

private struct GenerationValues: @unchecked Sendable {
    let imageURL: URL
    let prompt: String
    let kind: MLXRecoveryRuntime.GrammarKind
    let maxTokens: Int
    let decode: DecodeMode
    let uniqueSlotLetters: Set<Character>?
    let cache: GrammarCache
}

/// Holds the expensive, immutable part of grammar setup — the tokenizer
/// info xgrammar builds from the vocabulary — and compiles a fresh matcher
/// per call.
private final class GrammarCache: @unchecked Sendable {
    let tokenizer: GrammarTokenizer
    private let checkSchema: String

    init(tokenizer: GrammarTokenizer, checkSchema: String) {
        self.tokenizer = tokenizer
        self.checkSchema = checkSchema
    }

    func freshConstraint(for kind: MLXRecoveryRuntime.GrammarKind, hostTokenizer: any MLXLMCommon.Tokenizer) throws -> GrammarConstraint {
        let schema: String
        switch kind {
        case .check:
            schema = checkSchema
        case .rank(let slotCount):
            schema = MLXRecoveryRuntime.rankSchema(slotCount: slotCount)
        }
        return try GrammarConstraint(tokenizer: tokenizer, jsonSchema: schema, fastForward: true, hostTokenizer: hostTokenizer)
    }
}

private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
