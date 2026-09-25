import XCTest
@testable import Bricky

/// Model management around the delivery seam: preferences that survive a
/// relaunch, removal that really removes, and pruning that keeps only the pin.
@MainActor
final class RecoveryModelManagerTests: XCTestCase {
    private actor RecordingDelivery: ModelDelivery {
        private(set) var removed: [ModelManifest] = []
        func deliver(_ manifest: ModelManifest, progress: @escaping @Sendable (Double) async -> Void) async throws {}
        func remove(_ manifest: ModelManifest) async throws {
            removed.append(manifest)
            try? FileManager.default.removeItem(at: manifest.directory)
        }
    }

    private var root: URL!
    private var defaults: UserDefaults!
    private let suiteName = "RecoveryModelManagerTests"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func manager(delivery: any ModelDelivery = RecordingDelivery()) -> RecoveryModelManager {
        RecoveryModelManager(delivery: delivery, defaults: defaults, storageRoot: root, deviceFloor: { .noLiDAR })
    }

    func testCellularPreferenceSurvivesARelaunch() {
        let first = manager()
        XCTAssertFalse(first.allowsCellularDownloads)
        first.allowsCellularDownloads = true
        XCTAssertTrue(manager().allowsCellularDownloads)
    }

    func testPruneKeepsOnlyThePinnedRevision() throws {
        let subject = manager()
        let pinned = try XCTUnwrap(subject.modelDirectory)
        let models = pinned.deletingLastPathComponent().deletingLastPathComponent()
        let stale = models.appendingPathComponent("\(RecoveryModelManager.modelFolderName)/0000000000000000000000000000000000000000")
        let foreign = models.appendingPathComponent("Qwen3-VL-2B-Instruct-4bit/abc")
        for directory in [pinned, stale, foreign] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4_096).write(to: directory.appendingPathComponent("model.safetensors"))
        }

        subject.pruneStaleRevisions()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.appendingPathComponent("model.safetensors").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreign.deletingLastPathComponent().path))
        XCTAssertGreaterThan(subject.lastPrunedBytes, 0)
    }

    func testRemoveDeletesThePinnedRevisionThroughTheDelivery() async throws {
        let delivery = RecordingDelivery()
        let subject = manager(delivery: delivery)
        let pinned = try XCTUnwrap(subject.modelDirectory)
        try FileManager.default.createDirectory(at: pinned, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: pinned.appendingPathComponent("model.safetensors"))
        XCTAssertGreaterThan(subject.onDiskBytes, 0)

        try await subject.removeModel()
        let removed = await delivery.removed
        XCTAssertEqual(removed.map(\.revision), [RecoveryModelManager.revision])
        XCTAssertEqual(subject.onDiskBytes, 0)
        XCTAssertNil(subject.admissionSnapshot)
    }

    func testManifestURLsResolveThePinnedRevision() throws {
        let manifest = try XCTUnwrap(manager().manifest)
        let url = manifest.remoteURL(for: RecoveryModelManager.assets[0])
        XCTAssertTrue(url.absoluteString.contains("/resolve/\(RecoveryModelManager.revision)/"))
        XCTAssertEqual(manifest.totalBytes, RecoveryModelManager.assets.reduce(0) { $0 + $1.bytes })
    }
}
