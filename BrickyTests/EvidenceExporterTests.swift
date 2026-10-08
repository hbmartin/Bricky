import XCTest
@testable import Bricky

/// The session list the export screen shows, read back from the store.
final class EvidenceExporterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("exporter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSession(health: RecorderHealth?) throws -> UUID {
        let id = UUID()
        let directory = EvidenceExporter.storeDirectory(root: root).appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = EvidenceSessionFile(
            sessionVersion: EvidenceSchema.sessionVersion, sessionID: id, createdAt: .now, instructionSHA256: "abc",
            authoredModelID: UUID(), modelTitle: "Tower", stepCount: 4, modelRevision: "r", deviceModel: "iPhone18,1",
            operatingSystem: "iOS 27.0", appVersion: "1.0", captures: [], staged: nil, groundTruth: .unlabeled,
            estimate: nil, analysisError: nil, recorderHealth: health
        )
        try EvidenceSchema.encoder(prettyPrinted: true).encode(session)
            .write(to: directory.appendingPathComponent("session.json"))
        return id
    }

    // Fails on the old code by not compiling: the list could not say a
    // session had gaps.
    func testSummaryCarriesRecorderHealth() throws {
        let clean = try writeSession(health: nil)
        let gappy = try writeSession(health: RecorderHealth(
            writeFailures: 2, failedOperations: ["record captures": 2], windowsSkippedAtCap: 1, windowsSkippedLowSpace: 3
        ))
        let summaries = Dictionary(uniqueKeysWithValues: EvidenceExporter.listSessions(root: root).map { ($0.id, $0) })
        XCTAssertEqual(summaries[clean]?.recorderWriteFailures, 0)
        XCTAssertEqual(summaries[clean]?.windowsSkipped, 0)
        let summary = try XCTUnwrap(summaries[gappy])
        XCTAssertEqual(summary.recorderWriteFailures, 2)
        XCTAssertEqual(summary.windowsSkipped, 4)
        XCTAssertEqual(
            EvidenceSessionsView.gapsLabel(summary),
            "2 evidence writes failed, 4 verification windows skipped"
        )
    }
}
