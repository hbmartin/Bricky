import ArgumentParser
import Foundation
import RecoveryMLX

/// Writes what a converted adapter must look like for the pinned model,
/// and a zero-B adapter to prove the adapter path changes nothing by itself
/// (ADR 0019).
struct AdapterTemplateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adapter-template",
        abstract: "Write the pinned model's LoRA tensor template and a zero-B adapter (needs the weights).",
        discussion: """
        <out>/template.json lists every adapter tensor's name and shape and the
        dtype it must be stored in; convert_adapter.py checks against it.
        <out> is also a zero-B smoke adapter: replaying it must reproduce the
        baseline byte for byte.
        """
    )

    @Option(name: .customLong("model-dir"), help: "Directory containing the pinned model revision.")
    var modelDirectory: String

    @Option(name: .customLong("model-revision"), help: "Revision of the weights in --model-dir, recorded as the adapter's base.")
    var modelRevision: String

    @Option(help: "Output directory.")
    var out: String

    @Option(help: "LoRA rank.")
    var rank = 8

    @Option(help: "LoRA scale, written explicitly.")
    var scale: Float = 20

    @Option(help: "Wrap only the last N decoder layers (default: all).")
    var layers: Int?

    @Option(help: "Adapter name, [a-z0-9._-]+.")
    var name = "smoke-zero-b"

    @Option(help: "Seed for A's initial values.")
    var seed: UInt64 = 0

    mutating func run() async throws {
        let template = try await RecoveryAdapterTemplate.write(
            modelDirectory: URL(fileURLWithPath: modelDirectory), to: URL(fileURLWithPath: out), rank: rank,
            scale: scale, numLayers: layers, name: name, baseModelRevision: modelRevision, seed: seed
        )
        print("""
        wrote \(template.tensors.count) tensors over \(template.numLayers)/\(template.totalLayers) layers, \
        keys \(template.keys.joined(separator: ",")), dtype \(template.dtype) to \(out)
        """)
    }
}
