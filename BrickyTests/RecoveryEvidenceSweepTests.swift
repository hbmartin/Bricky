import XCTest
@testable import Bricky

final class RecoveryEvidenceSweepTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-tests-\(UUID().uuidString)", isDirectory: true)
        for folder in ["RecoveryCaptures", "InferenceBoards", "Evidence/session-1/boards"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relativePath: String) throws {
        try Data("x".utf8).write(to: root.appendingPathComponent(relativePath))
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    func testSweepRemovesOrphansKeepsReferencedAndNeverTouchesEvidence() throws {
        try write("RecoveryCaptures/referenced.jpg")
        try write("RecoveryCaptures/orphan.jpg")
        try write("InferenceBoards/board.jpg")
        try write("Evidence/session-1/session.json")
        try write("Evidence/session-1/boards/copy.jpg")

        RecoveryWorkFileCleanup.sweepOrphanedWorkFiles(
            root: root,
            referencedCapturePaths: ["RecoveryCaptures/referenced.jpg"]
        )

        XCTAssertTrue(exists("RecoveryCaptures/referenced.jpg"))
        XCTAssertFalse(exists("RecoveryCaptures/orphan.jpg"))
        XCTAssertFalse(exists("InferenceBoards/board.jpg"))
        XCTAssertTrue(exists("Evidence/session-1/session.json"))
        XCTAssertTrue(exists("Evidence/session-1/boards/copy.jpg"))
    }

    func testFailedMetadataFetchLeavesCapturesUntouchedButSweepsBoards() throws {
        try write("RecoveryCaptures/unknown.jpg")
        try write("InferenceBoards/board.jpg")

        RecoveryWorkFileCleanup.sweepOrphanedWorkFiles(root: root, referencedCapturePaths: nil)

        XCTAssertTrue(exists("RecoveryCaptures/unknown.jpg"))
        XCTAssertFalse(exists("InferenceBoards/board.jpg"))
    }
}
