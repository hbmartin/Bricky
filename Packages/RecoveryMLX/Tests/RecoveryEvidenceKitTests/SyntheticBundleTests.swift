import CoreGraphics
import XCTest
@testable import RecoveryEvidenceKit

/// A synthetic smoke bundle is a valid bundle that says what it is.
final class SyntheticBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func jpeg(_ grey: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: grey, green: grey, blue: grey, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let url = root.appendingPathComponent("\(UUID().uuidString).jpg")
        try RecoveryBoardLayoutV1.writeJPEG(try XCTUnwrap(context.makeImage()), to: url)
        return try Data(contentsOf: url)
    }

    private func sessions() throws -> [SyntheticEvidenceBundle.Session] {
        let tile = try jpeg(0.5)
        return [3, 5].map { truth in
            SyntheticEvidenceBundle.Session(
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(truth)")!,
                instructionSHA256: String(repeating: "a", count: 64),
                authoredModelID: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!,
                modelTitle: "Synthetic model 0", stepCount: 8, physicalBuildID: "synth-m0-b0",
                expectedCompletedCount: truth, expectedStepID: "synthetic-m0.ldr#\(truth)", capture: tile,
                traces: [SyntheticEvidenceBundle.Trace(
                    pass: .finalist, board: tile, tiles: ["A": tile, "B": tile],
                    candidateStepIndices: ["A": truth - 1, "B": truth],
                    candidateStepIDs: ["A": "synthetic-m0.ldr#\(truth)", "B": "synthetic-m0.ldr#\(truth + 1)"],
                    prompt: RecoveryPrompts.baselineRank, schemaJSON: "{}", maxTokens: 192
                )]
            )
        }
    }

    func testSyntheticBundleValidatesAndLoads() throws {
        let directory = root.appendingPathComponent("bundle")
        try SyntheticEvidenceBundle.write(
            try sessions(), to: directory, modelID: "m", modelRevision: "r", createdAt: Date(timeIntervalSince1970: 0)
        )
        let reader = try EvidenceBundleReader(bundleDirectory: directory)
        XCTAssertEqual(reader.validate(), [])
        XCTAssertEqual(reader.manifest.deviceModel, "synthetic:bricky-harness")
        let loaded = try reader.loadSessions()
        XCTAssertEqual(loaded.count, 2)
        for session in loaded {
            XCTAssertEqual(session.file.deviceModel, SyntheticEvidenceBundle.deviceModel)
            XCTAssertEqual(session.file.groundTruth.kind, .staged)
            XCTAssertEqual(session.file.physicalBuildID, "synth-m0-b0")
            let row = try XCTUnwrap(session.traceRows.first)
            XCTAssertEqual(row.termination, SyntheticEvidenceBundle.notRun)
            XCTAssertEqual(row.rawOutput, "")
            XCTAssertEqual(ReplayAggregation.truthSlot(row: row, expectedStepID: session.file.groundTruth.expectedStepID), "A")
        }
    }

    func testSyntheticBundleDeterministicForSeed() throws {
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let input = try sessions()
        for directory in [first, second] {
            try SyntheticEvidenceBundle.write(
                input, to: directory, modelID: "m", modelRevision: "r", createdAt: Date(timeIntervalSince1970: 0)
            )
        }
        let files = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: first.path)).sorted()
        XCTAssertEqual(files, try FileManager.default.subpathsOfDirectory(atPath: second.path).sorted())
        for file in files where file.hasSuffix(".json") || file.hasSuffix(".ndjson") || file.hasSuffix(".jpg") {
            XCTAssertEqual(
                try Data(contentsOf: first.appendingPathComponent(file)),
                try Data(contentsOf: second.appendingPathComponent(file)), file
            )
        }
        // Writing over an existing bundle is refused rather than merged.
        XCTAssertThrowsError(try SyntheticEvidenceBundle.write(
            input, to: first, modelID: "m", modelRevision: "r", createdAt: Date(timeIntervalSince1970: 0)
        ))
    }
}
