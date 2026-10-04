import XCTest
@testable import Bricky

/// Backups hold what the user made, never the ~3.1 GB recovery model or
/// other re-downloadable data. The root used to be re-marked as backed up on
/// every access, which swept the model into every iCloud backup.
final class StorageLayoutTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func isExcluded(_ area: StorageLayout.Area) throws -> Bool {
        let url = root.appendingPathComponent(area.rawValue, isDirectory: true)
        return try XCTUnwrap(url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup)
    }

    func testPolicyExcludesReDownloadableAndDeveloperData() throws {
        try StorageLayout.applyBackupPolicy(root: root)
        for area in [StorageLayout.Area.recoveryModels, .partPacks, .evidence, .staging, .inferenceBoards] {
            XCTAssertTrue(try isExcluded(area), area.rawValue)
        }
        for area in [StorageLayout.Area.models, .history, .recoveryCaptures] {
            XCTAssertFalse(try isExcluded(area), area.rawValue)
        }
    }

    func testPolicyIsIdempotentAndCorrectsEarlierMarks() throws {
        // An earlier build explicitly included everything.
        var models = root.appendingPathComponent("RecoveryModels", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try models.setResourceValues(values)

        try StorageLayout.applyBackupPolicy(root: root)
        try StorageLayout.applyBackupPolicy(root: root)
        XCTAssertTrue(try isExcluded(.recoveryModels))
    }

    func testDirectoryCreatesTheAreaWithItsPolicy() throws {
        let evidence = try StorageLayout.directory(.evidence, root: root)
        XCTAssertEqual(evidence.lastPathComponent, "Evidence")
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.path))
        XCTAssertTrue(try isExcluded(.evidence))
    }

    func testRootAccessNoLongerMarksItselfBackedUp() throws {
        let supportRoot = try InstructionModelImporter.applicationSupportRoot()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = supportRoot
        try mutable.setResourceValues(values)
        defer {
            var reset = URLResourceValues()
            reset.isExcludedFromBackup = false
            try? mutable.setResourceValues(reset)
        }
        _ = try InstructionModelImporter.applicationSupportRoot()
        let flag = try supportRoot.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(flag, true, "accessing the root must not rewrite backup flags")
    }
}
