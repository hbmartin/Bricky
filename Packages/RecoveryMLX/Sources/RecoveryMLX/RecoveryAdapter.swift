import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// A LoRA adapter for the pinned Qwen3-VL in mlx-swift-lm's format, as
/// `Tools/Training/convert_adapter.py` writes it (ADR 0019): `adapter_config.json`
/// beside `adapters.safetensors`. It is applied unfused over the pinned
/// weights, so they stay byte-identical, and a model variant names it as
/// `adapter=<identity>`.
///
/// Two traps at the pin make the checks here strict. The Swift and Python
/// scale defaults differ (10 against 20), so a config must spell out its
/// scale. And `LoRAContainer.load(into:)` verifies only that no key is
/// unused: a wrapped layer the file has no weights for keeps a random A
/// and a zero B, a silent no-op. So the file must cover every wrapped
/// layer, which is checked from the safetensors header before anything
/// loads.
public struct RecoveryAdapter: Sendable {
    /// The `bricky` block every converted config carries.
    public struct Provenance: Codable, Sendable, Equatable {
        public let name: String
        public let baseModelRevision: String
        /// True for a pipeline smoke adapter, which no release path accepts.
        public let smoke: Bool

        enum CodingKeys: String, CodingKey {
            case name
            case baseModelRevision = "base_model_revision"
            case smoke
        }
    }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case unconverted
        case missingParameter(String)
        case unsupportedType(String)
        case missingProvenance
        case invalidName(String)
        case unexpectedTensor(String)
        case incomplete(String)
        case incompatibleModel
        case wrongLayers(expected: [Int], found: [Int])
        case mixedDTypes([String])
        case wrongDType(expected: String, found: String)

        public var description: String {
            switch self {
            case .unreadable(let detail): "adapter is unreadable: \(detail)"
            case .unconverted: "adapter_config.json has `alpha`: an unconverted mlx-vlm adapter (run convert_adapter.py)"
            case .missingParameter(let name): "adapter_config.json must spell out lora_parameters.\(name)"
            case .unsupportedType(let type): "fine_tune_type \(type) is not supported; only lora"
            case .missingProvenance: "adapter_config.json has no bricky {name, base_model_revision, smoke} block"
            case .invalidName(let name): "adapter name \(name) must match [a-z0-9._-]+"
            case .unexpectedTensor(let key): "adapters.safetensors has an unexpected tensor \(key)"
            case .incomplete(let detail): "adapters.safetensors does not cover every wrapped layer: \(detail)"
            case .incompatibleModel: "the loaded model takes no LoRA adapter"
            case .wrongLayers(let expected, let found):
                "adapter covers layers \(found.first ?? -1)…\(found.last ?? -1), the model's last \(expected.count) are \(expected.first ?? -1)…\(expected.last ?? -1)"
            case .mixedDTypes(let types): "adapters.safetensors mixes dtypes \(types)"
            case .wrongDType(let expected, let found):
                "adapter tensors are \(found), the model computes in \(expected): the sum would promote every activation"
            }
        }
    }

    /// Where the language model's decoder layers sit in Qwen3-VL's module
    /// tree; adapter tensors are named `<prefix>.<layer>.<key>.lora_a|lora_b`.
    public static let layerPrefix = "language_model.model.layers."

    public let provenance: Provenance
    public let configuration: LoRAConfiguration
    /// The full SHA-256 of the config bytes followed by the weights bytes.
    public let sha256: String
    /// The decoder layers the file covers, ascending.
    public let layers: [Int]
    /// The safetensors dtype of every tensor (`BF16`, `F16`, `F32`). It must
    /// be the model's own: `QLoRALinear` adds `scale·x·A·B` to the layer's
    /// output, so float32 tensors would turn a bfloat16 model's activations
    /// into float32 and change every later result, even with B at zero.
    public let dtype: String
    let container: LoRAContainer

    /// `name@<first 12 hex of sha256>`, the variant's `adapter` value.
    public var identity: String { "\(provenance.name)@\(sha256.prefix(12))" }

    /// Everything checkable about an adapter directory without MLX.
    public struct Inspection: Sendable {
        public let provenance: Provenance
        public let configuration: LoRAConfiguration
        public let sha256: String
        public let layers: [Int]
        public let dtype: String

        public var identity: String { "\(provenance.name)@\(sha256.prefix(12))" }
    }

    /// Checks an adapter directory's config and safetensors header and
    /// hashes both files, without loading a tensor.
    public static func inspect(directory: URL) throws -> Inspection {
        let configData: Data
        let weightsData: Data
        do {
            configData = try Data(contentsOf: directory.appendingPathComponent("adapter_config.json"))
            weightsData = try Data(contentsOf: directory.appendingPathComponent("adapters.safetensors"), options: .mappedIfSafe)
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
        let (configuration, provenance) = try checkedConfiguration(configData)
        let header = try safetensorsHeader(weightsData)
        let layers = try checkedCoverage(header: header.mapValues(\.shape), configuration: configuration)
        let dtypes = Set(header.values.map(\.dtype)).sorted()
        guard dtypes.count == 1, let dtype = dtypes.first else { throw LoadError.mixedDTypes(dtypes) }
        return Inspection(
            provenance: provenance, configuration: configuration, sha256: identityHash(config: configData, weights: weightsData),
            layers: layers, dtype: dtype
        )
    }

    /// SHA-256 of the config bytes followed by the weights bytes, as hex.
    /// `convert_adapter.py` prints the same.
    public static func identityHash(config: Data, weights: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: config)
        hasher.update(data: weights)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Inspects an adapter directory, then maps its weights.
    public static func load(directory: URL) throws -> RecoveryAdapter {
        let inspection = try inspect(directory: directory)
        let container: LoRAContainer
        do {
            container = try LoRAContainer.from(directory: directory)
        } catch {
            throw LoadError.unreadable(String(describing: error))
        }
        return RecoveryAdapter(
            provenance: inspection.provenance, configuration: inspection.configuration, sha256: inspection.sha256,
            layers: inspection.layers, dtype: inspection.dtype, container: container
        )
    }

    /// The config, refused unless it is a converted LoRA config that spells
    /// out rank, scale and keys and carries its provenance.
    static func checkedConfiguration(_ data: Data) throws -> (LoRAConfiguration, Provenance) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.unreadable("adapter_config.json is not a JSON object")
        }
        if object["alpha"] != nil || object["lora_alpha"] != nil { throw LoadError.unconverted }
        guard let type = object["fine_tune_type"] as? String else { throw LoadError.missingParameter("fine_tune_type") }
        guard type == "lora" else { throw LoadError.unsupportedType(type) }
        guard object["num_layers"] is Int else { throw LoadError.missingParameter("num_layers") }
        guard let parameters = object["lora_parameters"] as? [String: Any] else {
            throw LoadError.missingParameter("lora_parameters")
        }
        for name in ["rank", "scale", "keys"] where parameters[name] == nil {
            throw LoadError.missingParameter(name)
        }
        guard let bricky = object["bricky"] else { throw LoadError.missingProvenance }
        let decoder = JSONDecoder()
        let provenance: Provenance
        let configuration: LoRAConfiguration
        do {
            provenance = try decoder.decode(Provenance.self, from: JSONSerialization.data(withJSONObject: bricky))
            configuration = try decoder.decode(LoRAConfiguration.self, from: data)
        } catch {
            throw LoadError.unreadable(String(describing: error))
        }
        let nameAllowed = !provenance.name.isEmpty && provenance.name.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || ".-_".unicodeScalars.contains(scalar)
        }
        guard nameAllowed else { throw LoadError.invalidName(provenance.name) }
        guard let keys = configuration.loraParameters.keys, !keys.isEmpty else { throw LoadError.missingParameter("keys") }
        return (configuration, provenance)
    }

    /// Tensor name → shape and dtype, from a safetensors file's JSON header,
    /// without touching MLX.
    static func safetensorsHeader(_ data: Data) throws -> [String: (shape: [Int], dtype: String)] {
        guard data.count >= 8 else { throw LoadError.unreadable("adapters.safetensors is truncated") }
        let length = data.prefix(8).enumerated().reduce(UInt64(0)) { value, element in
            value | UInt64(element.element) << (8 * UInt64(element.offset))
        }
        guard length > 0, UInt64(data.count) >= 8 + length else {
            throw LoadError.unreadable("adapters.safetensors header overruns the file")
        }
        let start = data.startIndex + 8
        let header = data[start..<(start + Int(length))]
        guard let object = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else {
            throw LoadError.unreadable("adapters.safetensors header is not JSON")
        }
        var tensors: [String: (shape: [Int], dtype: String)] = [:]
        for (key, value) in object where key != "__metadata__" {
            guard let entry = value as? [String: Any], let shape = entry["shape"] as? [Int],
                  let dtype = entry["dtype"] as? String else {
                throw LoadError.unreadable("adapters.safetensors entry \(key) has no shape or dtype")
            }
            tensors[key] = (shape, dtype)
        }
        return tensors
    }

    /// Every tensor must be `<layerPrefix><layer>.<key>.lora_a|lora_b` for a
    /// configured key, and the file must hold both halves of every key in
    /// exactly `num_layers` contiguous layers. Returns those layers.
    static func checkedCoverage(header: [String: [Int]], configuration: LoRAConfiguration) throws -> [Int] {
        let keys = Set(configuration.loraParameters.keys ?? [])
        var halves: [Int: [String: Set<String>]] = [:]
        for name in header.keys.sorted() {
            guard name.hasPrefix(layerPrefix) else { throw LoadError.unexpectedTensor(name) }
            let rest = name.dropFirst(layerPrefix.count)
            guard let dot = rest.firstIndex(of: "."), let layer = Int(rest[..<dot]) else {
                throw LoadError.unexpectedTensor(name)
            }
            let tail = rest[rest.index(after: dot)...]
            let half: String
            if tail.hasSuffix(".lora_a") {
                half = "lora_a"
            } else if tail.hasSuffix(".lora_b") {
                half = "lora_b"
            } else {
                throw LoadError.unexpectedTensor(name)
            }
            let key = String(tail.dropLast(half.count + 1))
            guard keys.contains(key) else { throw LoadError.unexpectedTensor(name) }
            halves[layer, default: [:]][key, default: []].insert(half)
        }
        let layers = halves.keys.sorted()
        guard layers.count == configuration.numLayers else {
            throw LoadError.incomplete("\(layers.count) layers in the file, num_layers is \(configuration.numLayers)")
        }
        guard let first = layers.first, layers == Array(first..<(first + layers.count)) else {
            throw LoadError.incomplete("layers \(layers) are not contiguous")
        }
        for layer in layers {
            for key in keys.sorted() where halves[layer]?[key] != ["lora_a", "lora_b"] {
                throw LoadError.incomplete("layer \(layer) \(key) lacks lora_a or lora_b")
            }
        }
        return layers
    }

    /// Wraps the loaded model's layers and loads the adapter's weights,
    /// refusing a file that does not cover exactly the model's last
    /// `num_layers` decoder layers, or whose dtype is not the model's.
    func apply(to container: ModelContainer) async throws {
        try await container.perform { context in
            guard let lora = context.model as? LoRAModel else { throw LoadError.incompatibleModel }
            let total = lora.loraLayers.count
            let expected = Array(max(0, total - configuration.numLayers)..<total)
            guard expected == layers else { throw LoadError.wrongLayers(expected: expected, found: layers) }
            if let computed = Self.computeDType(of: lora), computed != dtype {
                throw LoadError.wrongDType(expected: computed, found: dtype)
            }
            try self.container.load(into: context.model)
        }
    }

    /// The safetensors name of the dtype a model's decoder layers compute
    /// in: their quantization scales' for a quantized model, else their
    /// weights'.
    static func computeDType(of model: LoRAModel) -> String? {
        guard let layer = model.loraLayers.last else { return nil }
        let parameters = layer.parameters().flattened()
        let reference = parameters.first { $0.0.hasSuffix(".scales") } ?? parameters.first { $0.0.hasSuffix(".weight") }
        return reference.flatMap { safetensorsName($0.1.dtype) }
    }

    static func safetensorsName(_ dtype: DType) -> String? {
        switch dtype {
        case .bfloat16: "BF16"
        case .float16: "F16"
        case .float32: "F32"
        default: nil
        }
    }
}
