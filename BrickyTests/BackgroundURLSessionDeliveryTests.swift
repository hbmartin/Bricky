import CryptoKit
import XCTest
@testable import Bricky

/// Background delivery publishes only what verifies, in the foreground;
/// re-attaches instead of re-starting; and prefers resume data unless the
/// last attempt failed.
final class BackgroundURLSessionDeliveryTests: XCTestCase {
    /// Stands in for the background session: a started transfer "finishes"
    /// by writing the configured bytes as `<asset>.downloaded`, exactly as
    /// the real delegate hands a file over.
    private final class FakeTransfer: BackgroundTransferring, @unchecked Sendable {
        private let lock = NSLock()
        private var active: Set<String> = []
        private var failures: [String: Error] = [:]
        private(set) var started: [String] = []
        private(set) var resumed: [String] = []
        private(set) var cancelled: Set<String> = []
        var payloads: [String: Data] = [:]
        var destinations: [String: URL] = [:]
        /// Descriptions that stay in flight until `finish` is called.
        var holding: Set<String> = []
        /// Rounds a description pauses with resume data before landing,
        /// writing `pauseBytes` each time; -1 pauses forever.
        var pauses: [String: Int] = [:]
        var pauseBytes: Int64 = 0
        private var written: [String: Int64] = [:]

        func activeDescriptions() async -> Set<String> {
            lock.lock(); defer { lock.unlock() }
            return active
        }

        func start(_ request: URLRequest, description: String, expectedBytes: Int64) {
            lock.lock(); started.append(description); lock.unlock()
            land(description)
        }

        func resume(from resumeData: Data, description: String, expectedBytes: Int64) {
            lock.lock(); resumed.append(description); lock.unlock()
            land(description)
        }

        private func land(_ description: String) {
            if let remaining = pauses[description], remaining != 0 {
                pauses[description] = remaining - 1
                lock.lock(); written[description] = pauseBytes; lock.unlock()
                if let destination = destinations[description] {
                    try? Data("resume".utf8).write(to: BackgroundURLSessionDelivery.resumeDataURL(for: destination))
                }
                return
            }
            if holding.contains(description) {
                lock.lock(); active.insert(description); lock.unlock()
                return
            }
            if let payload = payloads[description], let destination = destinations[description] {
                try? payload.write(to: BackgroundURLSessionDelivery.downloadedURL(for: destination))
            }
        }

        func finish(_ description: String) {
            lock.lock(); active.remove(description); lock.unlock()
            if let payload = payloads[description], let destination = destinations[description] {
                try? payload.write(to: BackgroundURLSessionDelivery.downloadedURL(for: destination))
            }
        }

        func fail(_ description: String, with error: Error) {
            lock.lock(); failures[description] = error; lock.unlock()
        }

        func takeFailure(_ description: String) -> Error? {
            lock.lock(); defer { lock.unlock() }
            return failures.removeValue(forKey: description)
        }

        func bytesWritten(_ description: String) -> Int64 {
            lock.lock(); defer { lock.unlock() }
            return written[description] ?? 0
        }

        func cancel(_ descriptions: Set<String>) async {
            lock.lock(); cancelled.formUnion(descriptions); active.subtract(descriptions); lock.unlock()
        }
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-delivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func asset(_ path: String, _ data: Data) -> RecoveryModelManager.Asset {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(path: path, bytes: Int64(data.count), sha256: digest)
    }

    private func manifest(_ assets: [RecoveryModelManager.Asset]) -> ModelManifest {
        ModelManifest(modelID: "org/model", revision: "rev1", assets: assets, directory: directory)
    }

    private func delivery(_ transfer: FakeTransfer) -> BackgroundURLSessionDelivery {
        BackgroundURLSessionDelivery(transfer: transfer, pollInterval: .milliseconds(5))
    }

    private func wire(_ transfer: FakeTransfer, _ manifest: ModelManifest, payloads: [String: Data]) {
        for asset in manifest.assets {
            let description = BackgroundURLSessionDelivery.description(of: asset, in: manifest)
            transfer.destinations[description] = manifest.directory.appendingPathComponent(asset.path)
            transfer.payloads[description] = payloads[asset.path]
        }
    }

    func testDescriptionsNameTheRevisionAndAsset() {
        let config = asset("config.json", Data("{}".utf8))
        XCTAssertEqual(BackgroundURLSessionDelivery.description(of: config, in: manifest([config])), "rev1/config.json")
    }

    func testReconcilePublishesOnlyWhatVerifies() async throws {
        let good = Data("weights".utf8)
        let goodAsset = asset("model.safetensors", good)
        let badAsset = asset("tokenizer.json", Data("tokens".utf8))
        let subject = manifest([goodAsset, badAsset])
        let goodDestination = directory.appendingPathComponent(goodAsset.path)
        let badDestination = directory.appendingPathComponent(badAsset.path)
        try good.write(to: BackgroundURLSessionDelivery.downloadedURL(for: goodDestination))
        try Data("tampered".utf8).write(to: BackgroundURLSessionDelivery.downloadedURL(for: badDestination))

        let status = await delivery(FakeTransfer()).reconcile(subject)
        XCTAssertEqual(status, .idle)
        XCTAssertEqual(try Data(contentsOf: goodDestination), good)
        XCTAssertFalse(FileManager.default.fileExists(atPath: BackgroundURLSessionDelivery.downloadedURL(for: goodDestination).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: badDestination.path), "an unverified file is never published")
        XCTAssertFalse(FileManager.default.fileExists(atPath: BackgroundURLSessionDelivery.downloadedURL(for: badDestination).path))
    }

    func testReconcileReportsTransfersAPreviousLaunchStarted() async {
        let config = asset("config.json", Data("{}".utf8))
        let subject = manifest([config])
        let transfer = FakeTransfer()
        transfer.holding = ["rev1/config.json"]
        transfer.start(URLRequest(url: URL(string: "https://example.invalid")!), description: "rev1/config.json", expectedBytes: 2)
        let status = await delivery(transfer).reconcile(subject)
        XCTAssertEqual(status, .transferring)
    }

    func testDeliverStartsOnlyWhatIsMissingAndPublishesIt() async throws {
        let config = Data("{}".utf8), weights = Data("weights".utf8)
        let configAsset = asset("config.json", config), weightsAsset = asset("model.safetensors", weights)
        let subject = manifest([configAsset, weightsAsset])
        try config.write(to: directory.appendingPathComponent("config.json"))
        let transfer = FakeTransfer()
        wire(transfer, subject, payloads: ["model.safetensors": weights])

        try await delivery(transfer).deliver(subject, allowsCellular: false) { _ in }
        XCTAssertEqual(transfer.started, ["rev1/model.safetensors"], "published assets are never re-downloaded")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("model.safetensors")), weights)
    }

    func testDeliverReattachesInsteadOfStartingASecondTransfer() async throws {
        let weights = Data("weights".utf8)
        let weightsAsset = asset("model.safetensors", weights)
        let subject = manifest([weightsAsset])
        let transfer = FakeTransfer()
        wire(transfer, subject, payloads: ["model.safetensors": weights])
        transfer.holding = ["rev1/model.safetensors"]
        transfer.start(URLRequest(url: URL(string: "https://example.invalid")!), description: "rev1/model.safetensors", expectedBytes: 7)

        let delivering = Task { try await delivery(transfer).deliver(subject, allowsCellular: false) { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        transfer.finish("rev1/model.safetensors")
        try await delivering.value
        XCTAssertEqual(transfer.started.count, 1, "the running transfer was re-attached, not restarted")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("model.safetensors")), weights)
    }

    func testResumeDataIsUsedUnlessTheLastAttemptFailed() async throws {
        let weights = Data("weights".utf8)
        let weightsAsset = asset("model.safetensors", weights)
        let subject = manifest([weightsAsset])
        let destination = directory.appendingPathComponent(weightsAsset.path)
        let transfer = FakeTransfer()
        wire(transfer, subject, payloads: ["model.safetensors": weights])

        try Data("resume".utf8).write(to: BackgroundURLSessionDelivery.resumeDataURL(for: destination))
        try await delivery(transfer).deliver(subject, allowsCellular: false) { _ in }
        XCTAssertEqual(transfer.resumed, ["rev1/model.safetensors"])
        XCTAssertTrue(transfer.started.isEmpty)

        // Stale resume data after a failure (an expired signed URL) is
        // discarded for a fresh request.
        try FileManager.default.removeItem(at: destination)
        try Data("resume".utf8).write(to: BackgroundURLSessionDelivery.resumeDataURL(for: destination))
        transfer.fail("rev1/model.safetensors", with: URLError(.badServerResponse))
        try await delivery(transfer).deliver(subject, allowsCellular: false) { _ in }
        XCTAssertEqual(transfer.started, ["rev1/model.safetensors"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: BackgroundURLSessionDelivery.resumeDataURL(for: destination).path))
    }

    func testAnAssetThatNeverVerifiesGivesUp() async throws {
        let weightsAsset = asset("model.safetensors", Data("weights".utf8))
        let subject = manifest([weightsAsset])
        let transfer = FakeTransfer()
        wire(transfer, subject, payloads: ["model.safetensors": Data("corrupt".utf8)])
        do {
            try await delivery(transfer).deliver(subject, allowsCellular: false) { _ in }
            XCTFail("a file that never verifies must not loop forever")
        } catch {
            XCTAssertTrue(error is VerifiedAssetError, "the cause is the failed check: \(error)")
            XCTAssertEqual(transfer.started.count, 3)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.safetensors").path))
        }
    }

    func testPausesThatMakeProgressDoNotSpendTheRetryBudget() async throws {
        let weights = Data("weights".utf8)
        let weightsAsset = asset("model.safetensors", weights)
        let subject = manifest([weightsAsset])
        let transfer = FakeTransfer()
        wire(transfer, subject, payloads: ["model.safetensors": weights])
        // More pauses than `maximumAttempts`, each one writing more bytes.
        transfer.pauses["rev1/model.safetensors"] = 5
        transfer.pauseBytes = 1_024
        try await delivery(transfer).deliver(subject, allowsCellular: false) { _ in }
        XCTAssertEqual(transfer.started, ["rev1/model.safetensors"])
        XCTAssertEqual(transfer.resumed.count, 5)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("model.safetensors")), weights)
    }

    func testAStalledTransferGivesUpWithAStallNotAHashError() async throws {
        let weightsAsset = asset("model.safetensors", Data("weights".utf8))
        let subject = manifest([weightsAsset])
        let transfer = FakeTransfer()
        wire(transfer, subject, payloads: ["model.safetensors": Data("weights".utf8)])
        transfer.pauses["rev1/model.safetensors"] = -1
        do {
            try await delivery(transfer).deliver(subject, allowsCellular: false) { _ in }
            XCTFail("a transfer that never writes must not resume forever")
        } catch {
            XCTAssertEqual(error as? ModelTransferError, .stalled(asset: "model.safetensors"))
            XCTAssertEqual(transfer.started.count, 1)
            XCTAssertEqual(transfer.resumed.count, 3)
        }
    }

    func testRemoveCancelsTransfersAndDeletesTheRevision() async throws {
        let config = asset("config.json", Data("{}".utf8))
        let subject = manifest([config])
        let transfer = FakeTransfer()
        try await delivery(transfer).remove(subject)
        XCTAssertEqual(transfer.cancelled, ["rev1/config.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
