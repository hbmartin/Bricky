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

    private final class FakePressure: MemoryPressureSignaling {
        private var handler: (@MainActor @Sendable (MemoryPressureLevel) -> Void)?
        func start(_ handler: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void) { self.handler = handler }
        func stop() { handler = nil }
        func fire(_ level: MemoryPressureLevel) { handler?(level) }
    }

    private let gib: UInt64 = 1_024 * 1_024 * 1_024

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

    func testCriticalPressureCancelsInferenceAndMeasuresWhatWasFreed() async throws {
        let pressure = FakePressure()
        var readings = [
            MemoryBudget(availableBytes: 1 * gib, footprintBytes: 5 * gib),
            MemoryBudget(availableBytes: 4 * gib, footprintBytes: 2 * gib)
        ]
        let subject = RecoveryModelManager(
            delivery: RecordingDelivery(), defaults: defaults, storageRoot: root, deviceFloor: { .noLiDAR },
            memoryBudget: { readings.count > 1 ? readings.removeFirst() : readings[0] },
            pressure: pressure
        )
        let inference = Task { _ = try? await Task.sleep(for: .seconds(30)) }
        subject.trackInference(inference)

        pressure.fire(.critical)
        await inference.value
        XCTAssertTrue(inference.isCancelled, "critical pressure cancels in-flight inference")
        for _ in 0..<300 where subject.lastPressureRelief == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(subject.lastPressureRelief?.freedBytes, Int64(3 * gib), "re-read after the release, not before")
    }

    func testAWarningLeavesAnUnadmittedManagerAlone() async throws {
        let pressure = FakePressure()
        let subject = RecoveryModelManager(
            delivery: RecordingDelivery(), defaults: defaults, storageRoot: root, deviceFloor: { .noLiDAR },
            memoryBudget: { MemoryBudget(availableBytes: 0, footprintBytes: 0) },
            pressure: pressure
        )
        pressure.fire(.warning)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(subject.lastPressureRelief)
    }

    func testAdmissionReadsTheBudgetThroughTheGovernor() async {
        let subject = RecoveryModelManager(
            delivery: RecordingDelivery(), defaults: defaults, storageRoot: root, deviceFloor: { .supported },
            memoryBudget: { MemoryBudget(availableBytes: 2 * self.gib, footprintBytes: 1 * self.gib) },
            pressure: FakePressure()
        )
        await subject.check()
        guard case .rejected(let reason) = subject.state else {
            return XCTFail("a budget under the floor must refuse admission, got \(subject.state)")
        }
        XCTAssertTrue(reason.contains("memory"))
        XCTAssertTrue(subject.rejectionIsRetryable)
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
