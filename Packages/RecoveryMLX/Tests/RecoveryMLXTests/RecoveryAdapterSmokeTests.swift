import XCTest
@testable import RecoveryMLX

/// Adapters on the pinned weights (ADR 0019). Skipped unless
/// `BRICKY_MODEL_DIR` is set; the trained-adapter test also needs
/// `BRICKY_ADAPTER_DIR`.
final class RecoveryAdapterSmokeTests: XCTestCase {
    private static let revision = "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b"

    /// A zero-B adapter contributes exactly zero in the model's own dtype,
    /// so the generated text and the probe's probabilities must match the
    /// pinned model's bit for bit. This is what proves the adapter path
    /// adds nothing of its own.
    func testZeroBAdapterReproducesTheBaseline() async throws {
        let model = try TestBoards.modelDirectory()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("zero-b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try await RecoveryAdapterTemplate.write(
            modelDirectory: model, to: scratch, rank: 8, scale: 20, numLayers: nil,
            name: "smoke-zero-b", baseModelRevision: Self.revision, seed: 0
        )
        let adapter = try RecoveryAdapter.load(directory: scratch)
        XCTAssertEqual(adapter.dtype, "BF16")
        let board = try TestBoards.board(slots: 3, in: FileManager.default.temporaryDirectory)

        let plain = MLXRecoveryRuntime()
        let adapted = MLXRecoveryRuntime()
        await adapted.useAdapter(adapter)
        // The first call after a load is not bit-reproducible; the app and
        // the harness both warm up before anything is recorded. On this toy
        // board the check answer pads with whitespace to its token limit and
        // does not decode, with or without the adapter, so only the call is
        // made, as the harness does.
        for runtime in [plain, adapted] {
            _ = try await runtime.checkStepWithTrace(imageURL: board, prompt: MLXRecoveryRuntime.warmUpPrompt, modelDirectory: model)
        }
        let identity = await adapted.adapterIdentity
        XCTAssertEqual(identity, adapter.identity)
        for scoring in [ScoringMode.generate, .probe] {
            let expected = try await plain.rankWithTrace(
                imageURL: board, prompt: TestBoards.rankPrompt, candidateCount: 3, modelDirectory: model, scoring: scoring
            )
            let actual = try await adapted.rankWithTrace(
                imageURL: board, prompt: TestBoards.rankPrompt, candidateCount: 3, modelDirectory: model, scoring: scoring
            )
            XCTAssertEqual(actual.trace.rawOutput, expected.trace.rawOutput, "\(scoring)")
            XCTAssertEqual(actual.trace.probe, expected.trace.probe, "\(scoring)")
            XCTAssertEqual(actual.trace.readouts, expected.trace.readouts, "\(scoring)")
        }
        await plain.unload()
        await adapted.unload()
    }

    /// A trained (or converted) adapter still answers in the rank grammar.
    func testAdapterArmProducesGrammarValidOutput() async throws {
        let model = try TestBoards.modelDirectory()
        guard let path = ProcessInfo.processInfo.environment["BRICKY_ADAPTER_DIR"] else {
            throw XCTSkip("set BRICKY_ADAPTER_DIR to a converted adapter to run this test")
        }
        let adapter = try RecoveryAdapter.load(directory: URL(fileURLWithPath: path))
        let runtime = MLXRecoveryRuntime()
        await runtime.useAdapter(adapter)
        let rank = try await runtime.rankWithTrace(
            imageURL: try TestBoards.board(slots: 3, in: FileManager.default.temporaryDirectory),
            prompt: TestBoards.rankPrompt, candidateCount: 3, modelDirectory: model
        )
        print("adapter \(adapter.identity) rank: \(rank.trace.rawOutput)")
        XCTAssertEqual(rank.trace.termination, .accepted)
        let output = try XCTUnwrap(rank.output, rank.trace.decodeErrorDescription ?? "")
        XCTAssertTrue(output.ranking.allSatisfy { ["A", "B", "C"].contains($0) })
        await runtime.unload()
    }
}
