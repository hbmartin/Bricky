import XCTest
@testable import RecoveryMLX

/// A converted adapter is refused unless it spells out its scale and keys,
/// carries its provenance, and covers every wrapped layer. These checks read
/// only the config and the safetensors header, so they need no weights and
/// no GPU.
final class RecoveryAdapterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let keys = ["self_attn.q_proj", "self_attn.v_proj"]

    private func config(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object: [String: Any] = [
            "fine_tune_type": "lora",
            "num_layers": 2,
            "lora_parameters": ["rank": 4, "scale": 20.0, "keys": Self.keys],
            "bricky": ["name": "first-slot.v1", "base_model_revision": "rev", "smoke": false],
        ]
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// A safetensors file whose header names `tensors`; the payload is
    /// zeros of the right length.
    private func safetensors(_ tensors: [String: [Int]], dtype: String = "BF16") throws -> Data {
        var offset = 0
        var header: [String: Any] = [:]
        for (name, shape) in tensors.sorted(by: { $0.key < $1.key }) {
            let bytes = shape.reduce(1, *) * 2
            header[name] = ["dtype": dtype, "shape": shape, "data_offsets": [offset, offset + bytes]]
            offset += bytes
        }
        let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var data = Data((0..<8).map { UInt8(truncatingIfNeeded: UInt64(json.count) >> (8 * UInt64($0))) })
        data.append(json)
        data.append(Data(count: offset))
        return data
    }

    private func tensors(layers: [Int], keys: [String] = keys) -> [String: [Int]] {
        var tensors: [String: [Int]] = [:]
        for layer in layers {
            for key in keys {
                tensors["language_model.model.layers.\(layer).\(key).lora_a"] = [16, 4]
                tensors["language_model.model.layers.\(layer).\(key).lora_b"] = [4, 16]
            }
        }
        return tensors
    }

    private func write(config: Data, weights: Data) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try config.write(to: directory.appendingPathComponent("adapter_config.json"))
        try weights.write(to: directory.appendingPathComponent("adapters.safetensors"))
        return directory
    }

    private func refusal(config: Data, weights: Data) throws -> RecoveryAdapter.LoadError? {
        do {
            _ = try RecoveryAdapter.inspect(directory: try write(config: config, weights: weights))
            return nil
        } catch let error as RecoveryAdapter.LoadError {
            return error
        }
    }

    func testAConvertedAdapterPassesInspection() throws {
        let inspection = try RecoveryAdapter.inspect(
            directory: try write(config: try config(), weights: try safetensors(tensors(layers: [34, 35])))
        )
        XCTAssertEqual(inspection.layers, [34, 35])
        XCTAssertEqual(inspection.dtype, "BF16")
        XCTAssertEqual(inspection.configuration.loraParameters.scale, 20)
        XCTAssertEqual(inspection.provenance, .init(name: "first-slot.v1", baseModelRevision: "rev", smoke: false))
        XCTAssertTrue(inspection.identity.hasPrefix("first-slot.v1@"))
        XCTAssertEqual(inspection.identity.count, "first-slot.v1@".count + 12)
    }

    func testIdentityHashIsStableAndCoversBothFiles() throws {
        let configData = try config()
        let weights = try safetensors(tensors(layers: [0, 1]))
        let first = try RecoveryAdapter.inspect(directory: try write(config: configData, weights: weights))
        let second = try RecoveryAdapter.inspect(directory: try write(config: configData, weights: weights))
        XCTAssertEqual(first.sha256, second.sha256)
        XCTAssertEqual(first.sha256, RecoveryAdapter.identityHash(config: configData, weights: weights))
        var changed = weights
        changed[changed.count - 1] = 1
        XCTAssertNotEqual(RecoveryAdapter.identityHash(config: configData, weights: changed), first.sha256)
    }

    func testConfigRefusals() throws {
        let weights = try safetensors(tensors(layers: [0, 1]))
        let cases: [(String, (inout [String: Any]) -> Void, RecoveryAdapter.LoadError)] = [
            ("scale left to a default", { $0["lora_parameters"] = ["rank": 4, "keys": Self.keys] }, .missingParameter("scale")),
            ("rank left to a default", { $0["lora_parameters"] = ["scale": 20.0, "keys": Self.keys] }, .missingParameter("rank")),
            ("keys left to a default", { $0["lora_parameters"] = ["rank": 4, "scale": 20.0] }, .missingParameter("keys")),
            ("an unconverted mlx-vlm config", { $0["alpha"] = 16 }, .unconverted),
            ("DoRA", { $0["fine_tune_type"] = "dora" }, .unsupportedType("dora")),
            ("no provenance", { $0.removeValue(forKey: "bricky") }, .missingProvenance),
            ("a name that breaks the variant id", {
                $0["bricky"] = ["name": "a,b", "base_model_revision": "rev", "smoke": false]
            }, .invalidName("a,b")),
        ]
        for (label, edit, expected) in cases {
            XCTAssertEqual(try refusal(config: try config(edit), weights: weights), expected, label)
        }
    }

    func testCoverageRefusals() throws {
        let configData = try config()
        // A wrapped layer with no weights would keep B at zero: a silent no-op.
        var missingHalf = tensors(layers: [0, 1])
        missingHalf.removeValue(forKey: "language_model.model.layers.1.self_attn.v_proj.lora_b")
        XCTAssertEqual(
            try refusal(config: configData, weights: try safetensors(missingHalf)),
            .incomplete("layer 1 self_attn.v_proj lacks lora_a or lora_b")
        )
        XCTAssertEqual(
            try refusal(config: configData, weights: try safetensors(tensors(layers: [0]))),
            .incomplete("1 layers in the file, num_layers is 2")
        )
        XCTAssertEqual(
            try refusal(config: configData, weights: try safetensors(tensors(layers: [0, 2]))),
            .incomplete("layers [0, 2] are not contiguous")
        )
        var stray = tensors(layers: [0, 1])
        stray["vision_tower.blocks.0.attn.qkv.lora_a"] = [16, 4]
        XCTAssertEqual(
            try refusal(config: configData, weights: try safetensors(stray)),
            .unexpectedTensor("vision_tower.blocks.0.attn.qkv.lora_a")
        )
        let unconfigured = tensors(layers: [0, 1], keys: Self.keys + ["mlp.up_proj"])
        XCTAssertEqual(
            try refusal(config: configData, weights: try safetensors(unconfigured)),
            .unexpectedTensor("language_model.model.layers.0.mlp.up_proj.lora_a")
        )
        // mlx-vlm's own parameter names are not mlx-swift-lm's.
        let renamed = Dictionary(uniqueKeysWithValues: tensors(layers: [0, 1]).map { name, shape in
            (name.replacingOccurrences(of: ".lora_a", with: ".A"), shape)
        })
        XCTAssertNotNil(try refusal(config: configData, weights: try safetensors(renamed)))
    }

    func testMixedDTypesAreRefused() throws {
        var data = try safetensors(tensors(layers: [0, 1]))
        // Rewrite one entry's dtype in place: same length, so offsets hold.
        let text = String(decoding: data, as: UTF8.self)
        let range = try XCTUnwrap(text.range(of: "BF16"))
        let offset = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
        data.replaceSubrange(offset..<(offset + 4), with: Data("F32 ".utf8))
        XCTAssertNotNil(try refusal(config: try config(), weights: data))
    }
}
