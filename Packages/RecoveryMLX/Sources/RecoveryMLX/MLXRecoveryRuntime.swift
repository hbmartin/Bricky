import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon
import MLXVLM
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

    public var errorDescription: String? {
        "The on-device model did not produce a valid guided result."
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

    public init() {}

    public func load(modelDirectory: URL) async throws {
        _ = try await modelContainer(modelDirectory: modelDirectory)
    }

    /// GuidedGenerationLoop reserves 64 tokens for its closing bias. The
    /// worst-case 8-slot ranking JSON is ~64 tokens under grammar masking, so
    /// the previous 96 put the bias mid-array; 192 keeps the whole object out
    /// of the soft zone. Generation still halts at grammar acceptance, so the
    /// common case pays nothing.
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

    /// `maxTokens` overrides the default rank budget — an A/B knob for the
    /// Mac harness; the app always passes nil.
    public func rankWithTrace(imageURL: URL, prompt: String, candidateCount: Int, modelDirectory: URL, maxTokens: Int? = nil) async throws -> MLXRankResponse {
        let generated = try await generate(
            imageURL: imageURL,
            prompt: prompt,
            kind: .rank(slotCount: candidateCount),
            modelDirectory: modelDirectory,
            maxTokens: maxTokens ?? Self.rankMaxTokens
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

    public func checkStepWithTrace(imageURL: URL, prompt: String, modelDirectory: URL) async throws -> MLXCheckResponse {
        let generated = try await generate(
            imageURL: imageURL,
            prompt: prompt,
            kind: .check,
            modelDirectory: modelDirectory,
            maxTokens: Self.checkMaxTokens
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
        var inFlight = loadTask
        // Clear state before suspending so reentrant callers observe the
        // unloading barrier immediately and cannot start replacement loads.
        loadTask = nil
        grammarCache = nil
        container = nil
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
        MLX.Memory.clearCache()
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

        func trace(decodeError: String?, schemaJSON: String) -> MLXGenerationTrace {
            MLXGenerationTrace(
                rawOutput: text,
                decodeErrorDescription: decodeError,
                generatedTokens: generatedTokens,
                termination: termination,
                latencyMilliseconds: latencyMilliseconds,
                maxTokens: maxTokens,
                schemaJSON: schemaJSON
            )
        }
    }

    private func generate(
        imageURL: URL,
        prompt: String,
        kind: GrammarKind,
        modelDirectory: URL,
        maxTokens: Int
    ) async throws -> GeneratedText {
        try Task.checkCancellation()
        let container = try await modelContainer(modelDirectory: modelDirectory)
        let cache = try await grammarResources(container: container)
        let started = ContinuousClock.now
        return try await container.perform(values: GenerationValues(
            imageURL: imageURL,
            prompt: prompt,
            kind: kind,
            maxTokens: maxTokens,
            cache: cache
        )) { context, values in
            var userInput = UserInput(prompt: values.prompt, images: [.url(values.imageURL)])
            userInput.processing = .init(resize: CGSize(width: 1024, height: 1024))
            let input = try await context.processor.prepare(input: userInput)
            let root = values.cache.rootConstraint(for: values.kind)
            // A matcher is stateful. Clone the compiled root for every stateless call.
            let constraint = try root.clone()
            var output = ""
            var generatedTokens: Int?
            var termination = MLXGenerationTrace.Termination.accepted
            do {
                generatedTokens = try GuidedGenerationLoop.run(
                    input: input,
                    context: context,
                    constraint: constraint,
                    maxTokens: values.maxTokens,
                    vocabSize: values.cache.tokenizer.vocabSize
                ) { delta in
                    output += delta
                    return !Task.isCancelled
                }
            } catch GuidedGenerationError.incompleteOutput {
                // The partial text is evidence; before this catch it was
                // destroyed and truncation was unobservable.
                termination = .maxTokensExhausted
            } catch GuidedGenerationError.prematureEOS {
                termination = .prematureEOS
            }
            try Task.checkCancellation()
            let elapsed = started.duration(to: .now).components
            return GeneratedText(
                text: output,
                generatedTokens: generatedTokens,
                termination: termination,
                latencyMilliseconds: Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000),
                maxTokens: values.maxTokens
            )
        }
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
        let task = Task<ModelContainer, Error> {
            try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory,
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
            // Compile every slot-count variant up front. The cost lands in the
            // admission warm-up, and the immutable array keeps the cache free
            // of locking under @unchecked Sendable.
            let rankConstraints = try (1...Self.rankSlotLetters.count).map { count in
                try GrammarConstraint(
                    tokenizer: tokenizer,
                    jsonSchema: Self.rankSchema(slotCount: count),
                    fastForward: true,
                    hostTokenizer: context.tokenizer
                )
            }
            return GrammarCache(
                tokenizer: tokenizer,
                rankConstraints: rankConstraints,
                checkConstraint: try GrammarConstraint(
                    tokenizer: tokenizer,
                    jsonSchema: Self.checkSchema,
                    fastForward: true,
                    hostTokenizer: context.tokenizer
                )
            )
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
    let cache: GrammarCache
}

private final class GrammarCache: @unchecked Sendable {
    let tokenizer: GrammarTokenizer
    /// Index N-1 holds the constraint permitting slots A through the Nth letter.
    private let rankConstraints: [GrammarConstraint]
    private let checkConstraint: GrammarConstraint

    init(tokenizer: GrammarTokenizer, rankConstraints: [GrammarConstraint], checkConstraint: GrammarConstraint) {
        self.tokenizer = tokenizer
        self.rankConstraints = rankConstraints
        self.checkConstraint = checkConstraint
    }

    func rootConstraint(for kind: MLXRecoveryRuntime.GrammarKind) -> GrammarConstraint {
        switch kind {
        case .check:
            checkConstraint
        case .rank(let slotCount):
            rankConstraints[min(max(slotCount, 1), rankConstraints.count) - 1]
        }
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
