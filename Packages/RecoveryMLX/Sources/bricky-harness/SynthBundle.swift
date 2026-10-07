import ArgumentParser
import CoreGraphics
import CryptoKit
import Foundation
import RecoveryEvidenceKit
import RecoveryMLX

/// Writes a synthetic smoke bundle for the LoRA pipeline's end-to-end test
/// (ADR 0019): stacked coloured blocks, one more per step, as in the
/// weights-gated tests' boards. The truth is the tile whose block count
/// matches the "physical" image. It is a pipeline fixture, not a sensor
/// model, and every release and training path refuses its device model.
struct SynthBundle: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "synth-bundle",
        abstract: "Write a synthetic smoke bundle of stacked-block boards (pipeline tests only; never evidence).",
        discussion: """
        Each session is staged at a known step, with one finalist board of up
        to four candidate steps around it in a seeded slot order. Authored
        models differ in palette, physical builds in block shape, so the
        exporter's model-and-build split has something to split.
        """
    )

    @Option(help: "Output bundle directory; must not exist.")
    var out: String

    @Option(name: .customLong("authored-models"), help: "Distinct synthetic instruction models.")
    var authoredModels = 4

    @Option(name: .customLong("builds-per-model"), help: "Physical builds per model.")
    var buildsPerModel = 2

    @Option(help: "Sessions per physical build.")
    var sessions = 6

    @Option(help: "Seed for staged steps and slot order.")
    var seed: UInt64 = 7

    @Option(name: .customLong("model-revision"), help: "The base revision recorded on the bundle.")
    var modelRevision = "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b"

    static let stepCount = 8
    static let palettes: [[(CGFloat, CGFloat, CGFloat)]] = [
        [(0.8, 0.1, 0.1), (0.1, 0.3, 0.8), (0.95, 0.8, 0.1), (0.1, 0.6, 0.2)],
        [(0.1, 0.6, 0.6), (0.6, 0.2, 0.6), (0.9, 0.5, 0.1), (0.3, 0.3, 0.3)],
        [(0.2, 0.2, 0.7), (0.7, 0.7, 0.2), (0.7, 0.2, 0.2), (0.2, 0.7, 0.4)],
        [(0.5, 0.3, 0.1), (0.1, 0.5, 0.8), (0.8, 0.3, 0.5), (0.4, 0.6, 0.1)],
    ]

    mutating func validate() throws {
        guard (1...Self.palettes.count).contains(authoredModels) else {
            throw ValidationError("--authored-models must be 1...\(Self.palettes.count)")
        }
        guard buildsPerModel >= 1, sessions >= 1 else { throw ValidationError("need at least one build and session") }
    }

    mutating func run() throws {
        var generator = SeededGenerator(seed: seed)
        var written: [SyntheticEvidenceBundle.Session] = []
        for model in 0..<authoredModels {
            let sha = SHA256.hash(data: Data("synthetic-model-\(model)".utf8)).map { String(format: "%02x", $0) }.joined()
            let modelID = Self.uuid(fromHex: sha)
            let root = "synthetic-m\(model).ldr"
            for build in 0..<buildsPerModel {
                let style = BlockStyle(palette: Self.palettes[model], widthFraction: 0.4 + 0.12 * CGFloat(build % 3))
                for index in 0..<sessions {
                    let truth = Int.random(in: 2...(Self.stepCount - 1), using: &generator)
                    let steps = Array(max(1, truth - 2)...min(Self.stepCount, truth + 1)).shuffled(using: &generator)
                    let slots = steps.indices.map { String(UnicodeScalar(UInt8(65 + $0))) }
                    // The board's hero region is about 2.36:1; a photo of that
                    // shape is shown whole, so every block can be counted.
                    let physical = try style.blocks(truth, width: 2360, height: 1000)
                    let tiles = try steps.map { try style.blocks($0, width: 512, height: 384) }
                    let board = try RecoveryBoardLayoutV1.composeBoard(
                        physical: physical,
                        candidates: zip(slots, zip(tiles, steps)).map { slot, tile in
                            RecoveryBoardLayoutV1.Candidate(slot: slot, image: tile.0, stepNumber: tile.1)
                        }
                    )
                    let trace = SyntheticEvidenceBundle.Trace(
                        pass: .finalist,
                        board: try Self.jpeg(board),
                        tiles: Dictionary(uniqueKeysWithValues: try zip(slots, tiles).map { ($0, try Self.jpeg($1)) }),
                        candidateStepIndices: Dictionary(uniqueKeysWithValues: zip(slots, steps.map { $0 - 1 })),
                        candidateStepIDs: Dictionary(uniqueKeysWithValues: zip(slots, steps.map { "\(root)#\($0)" })),
                        prompt: RecoveryPrompts.baselineRank,
                        schemaJSON: MLXRecoveryRuntime.rankSchema(slotCount: slots.count),
                        maxTokens: 192
                    )
                    let sessionKey = "synthetic-m\(model)-b\(build)-s\(index)-\(seed)"
                    let sessionSHA = SHA256.hash(data: Data(sessionKey.utf8)).map { String(format: "%02x", $0) }.joined()
                    written.append(SyntheticEvidenceBundle.Session(
                        sessionID: Self.uuid(fromHex: sessionSHA),
                        instructionSHA256: sha,
                        authoredModelID: modelID,
                        modelTitle: "Synthetic model \(model)",
                        stepCount: Self.stepCount,
                        physicalBuildID: "synth-m\(model)-b\(build)",
                        expectedCompletedCount: truth,
                        expectedStepID: "\(root)#\(truth)",
                        capture: try Self.jpeg(physical),
                        traces: [trace]
                    ))
                }
            }
        }
        try SyntheticEvidenceBundle.write(
            written, to: URL(fileURLWithPath: out),
            modelID: "mlx-community/Qwen3-VL-4B-Instruct-4bit", modelRevision: modelRevision,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        print("wrote \(written.count) synthetic sessions (\(authoredModels) models × \(buildsPerModel) builds) to \(out); device model \(SyntheticEvidenceBundle.deviceModel)")
    }

    static func uuid(fromHex hex: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var index = hex.startIndex
        for byte in 0..<16 {
            let next = hex.index(index, offsetBy: 2)
            bytes[byte] = UInt8(hex[index..<next], radix: 16) ?? 0
            index = next
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func jpeg(_ image: CGImage) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synth-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecoveryBoardLayoutV1.writeJPEG(image, to: url)
        return try Data(contentsOf: url)
    }
}

/// How one physical build draws its blocks: the model's palette, the
/// build's block width.
private struct BlockStyle {
    let palette: [(CGFloat, CGFloat, CGFloat)]
    let widthFraction: CGFloat

    func blocks(_ count: Int, width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.featureUnsupported) }
        context.setFillColor(CGColor(srgbRed: 0.92, green: 0.92, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let blockHeight = CGFloat(height) / 12
        for index in 0..<count {
            let (red, green, blue) = palette[index % palette.count]
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(
                x: CGFloat(width) * (1 - widthFraction) / 2, y: CGFloat(height) * 0.1 + CGFloat(index) * blockHeight,
                width: CGFloat(width) * widthFraction, height: blockHeight * 0.9
            ))
        }
        guard let image = context.makeImage() else { throw CocoaError(.featureUnsupported) }
        return image
    }
}

/// SplitMix64: the same seeded sequence on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
