import Foundation
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
    private static let rankSchema = #"{"type":"object","properties":{"status":{"type":"string","enum":["matched","insufficient"]},"ranking":{"type":"array","items":{"type":"string","enum":["A","B","C","D","E","F","G","H"]},"maxItems":8,"uniqueItems":true}},"required":["status","ranking"],"additionalProperties":false}"#
    private static let checkSchema = #"{"type":"object","properties":{"result":{"type":"string","enum":["complete","incomplete","uncertain"]}},"required":["result"],"additionalProperties":false}"#

    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    private var grammarCache: GrammarCache?

    public init() {}

    public func load(modelDirectory: URL) async throws {
        _ = try await modelContainer(modelDirectory: modelDirectory)
    }

    public func rank(imageURL: URL, prompt: String, modelDirectory: URL) async throws -> MLXRankOutput {
        let output = try await generate(
            imageURL: imageURL,
            prompt: prompt,
            kind: .rank,
            modelDirectory: modelDirectory,
            maxTokens: 96
        )
        guard let value = try? JSONDecoder().decode(MLXRankOutput.self, from: Data(output.utf8)) else {
            throw MLXRecoveryError.invalidStructuredOutput
        }
        return value
    }

    public func checkStep(imageURL: URL, prompt: String, modelDirectory: URL) async throws -> MLXStepCheckOutput {
        let output = try await generate(
            imageURL: imageURL,
            prompt: prompt,
            kind: .check,
            modelDirectory: modelDirectory,
            maxTokens: 48
        )
        guard let value = try? JSONDecoder().decode(MLXStepCheckOutput.self, from: Data(output.utf8)) else {
            throw MLXRecoveryError.invalidStructuredOutput
        }
        return value
    }

    /// Production-sized fit test. Loading weights alone is not admission.
    public func warmUp(imageURL: URL, modelDirectory: URL) async throws {
        _ = try await checkStep(
            imageURL: imageURL,
            prompt: "Return uncertain. This is a device fit test.",
            modelDirectory: modelDirectory
        )
    }

    public func unload() {
        loadTask?.cancel()
        loadTask = nil
        grammarCache = nil
        container = nil
    }

    fileprivate enum GrammarKind: Sendable { case rank, check }

    private func generate(
        imageURL: URL,
        prompt: String,
        kind: GrammarKind,
        modelDirectory: URL,
        maxTokens: Int
    ) async throws -> String {
        try Task.checkCancellation()
        let container = try await modelContainer(modelDirectory: modelDirectory)
        let cache = try await grammarResources(container: container)
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
            let root = switch values.kind {
            case .rank: values.cache.rankConstraint
            case .check: values.cache.checkConstraint
            }
            // A matcher is stateful. Clone the compiled root for every stateless call.
            let constraint = try root.clone()
            var output = ""
            try GuidedGenerationLoop.run(
                input: input,
                context: context,
                constraint: constraint,
                maxTokens: values.maxTokens,
                vocabSize: values.cache.tokenizer.vocabSize
            ) { delta in
                output += delta
                return !Task.isCancelled
            }
            try Task.checkCancellation()
            return output
        }
    }

    private func modelContainer(modelDirectory: URL) async throws -> ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }
        let task = Task<ModelContainer, Error> {
            try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: TransformersTokenizerLoader()
            )
        }
        loadTask = task
        do {
            let loaded = try await task.value
            container = loaded
            loadTask = nil
            return loaded
        } catch {
            loadTask = nil
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
            return try GrammarCache(
                tokenizer: tokenizer,
                rankConstraint: GrammarConstraint(
                    tokenizer: tokenizer,
                    jsonSchema: Self.rankSchema,
                    fastForward: true,
                    hostTokenizer: context.tokenizer
                ),
                checkConstraint: GrammarConstraint(
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
    let rankConstraint: GrammarConstraint
    let checkConstraint: GrammarConstraint

    init(tokenizer: GrammarTokenizer, rankConstraint: GrammarConstraint, checkConstraint: GrammarConstraint) {
        self.tokenizer = tokenizer
        self.rankConstraint = rankConstraint
        self.checkConstraint = checkConstraint
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
