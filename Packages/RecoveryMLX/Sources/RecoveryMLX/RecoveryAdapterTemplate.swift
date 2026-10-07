import Foundation
import MLX
import MLXLMCommon
import MLXNN
import MLXVLM

/// What a converted adapter for the pinned model must look like, read from
/// the Swift model itself: every tensor's name and shape, and the dtype it
/// must be stored in. `convert_adapter.py` checks its output against this,
/// so a Python-side naming or orientation mistake fails in Python, before a
/// replay can quietly run a no-op adapter.
public struct RecoveryAdapterTemplate: Codable, Sendable, Equatable {
    public var layerPrefix: String
    public var dtype: String
    public var totalLayers: Int
    public var numLayers: Int
    public var keys: [String]
    public var tensors: [String: [Int]]

    enum CodingKeys: String, CodingKey {
        case layerPrefix = "layer_prefix"
        case dtype
        case totalLayers = "total_layers"
        case numLayers = "num_layers"
        case keys
        case tensors
    }

    /// Loads the model at `modelDirectory`, wraps its last `numLayers`
    /// decoder layers (all, when nil) for LoRA on every default key, and
    /// writes to `directory`: `template.json`, plus a zero-B adapter in the
    /// model's dtype (`adapter_config.json`, `adapters.safetensors`), whose
    /// sum is exactly zero, so replaying it must reproduce the baseline.
    public static func write(
        modelDirectory: URL, to directory: URL, rank: Int, scale: Float, numLayers: Int?,
        name: String, baseModelRevision: String, seed: UInt64
    ) async throws -> RecoveryAdapterTemplate {
        let container = try await VLMModelFactory.shared.loadContainer(
            from: try LoadableModelDirectory.resolve(modelDirectory),
            using: TransformersTokenizerLoader()
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await container.perform { context in
            guard let model = context.model as? LoRAModel else { throw RecoveryAdapter.LoadError.incompatibleModel }
            let total = model.loraLayers.count
            let layers = min(numLayers ?? total, total)
            let keys = model.loraDefaultKeys.sorted()
            guard let dtypeName = RecoveryAdapter.computeDType(of: model) else {
                throw RecoveryAdapter.LoadError.unreadable("the model's compute dtype is not a float type")
            }
            let dtype: DType = switch dtypeName {
            case "BF16": .bfloat16
            case "F16": .float16
            default: .float32
            }
            let configuration = LoRAConfiguration(
                numLayers: layers, fineTuneType: .lora,
                loraParameters: .init(rank: rank, scale: scale, keys: keys)
            )
            MLXRandom.seed(seed)
            let adapter = try LoRAContainer.from(model: context.model, configuration: configuration)
            // A fresh LoRA layer starts with B at zero and A uniform: a real
            // adapter whose contribution is exactly zero.
            let arrays = Dictionary(uniqueKeysWithValues: adapter.parameters.flattened().map { name, array in
                (name, array.asType(dtype))
            })
            eval(Array(arrays.values))
            try MLX.save(arrays: arrays, url: directory.appendingPathComponent("adapters.safetensors"))

            let config: [String: Any] = [
                "fine_tune_type": "lora",
                "num_layers": layers,
                "lora_parameters": ["rank": rank, "scale": scale, "keys": keys],
                "bricky": ["name": name, "base_model_revision": baseModelRevision, "smoke": true],
            ]
            try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("adapter_config.json"))

            let template = RecoveryAdapterTemplate(
                layerPrefix: RecoveryAdapter.layerPrefix, dtype: dtypeName, totalLayers: total, numLayers: layers,
                keys: keys, tensors: arrays.mapValues { $0.shape }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(template).write(to: directory.appendingPathComponent("template.json"))
            return template
        }
    }
}
