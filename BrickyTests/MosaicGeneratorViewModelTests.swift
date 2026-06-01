import XCTest
@testable import Bricky

// MARK: - MosaicGeneratorViewModel Tests
//
// Drives the view model through its full phase machine using a real
// MosaicGenerationService backed by the stubbed URLProtocol from
// MosaicGenerationServiceTests. Covers:
//   1. Happy path: submit → poll → completed (with parts + grid hydrated)
//   2. Server-error job → .failed
//   3. Transport failure → .failed
//   4. Pro gating via injected isProProvider
//   5. canGenerate / isBusy derived state

@MainActor
final class MosaicGeneratorViewModelTests: XCTestCase {

    private let baseURL = URL(string: "https://mosaic.test")!

    override func tearDown() {
        MosaicURLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeService() -> MosaicGenerationService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MosaicURLProtocolStub.self]
        let session = URLSession(configuration: config)
        return MosaicGenerationService(baseURL: baseURL, session: session)
    }

    private func makeViewModel(isPro: Bool = true) -> MosaicGeneratorViewModel {
        MosaicGeneratorViewModel(
            service: makeService(),
            pollInterval: .milliseconds(1),
            isProProvider: { isPro }
        )
    }

    private func solidImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func pngData() -> Data {
        solidImage().pngData() ?? Data()
    }

    /// Wait until `condition` holds or a timeout elapses, pumping the runloop.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Happy Path

    func testGenerateReachesCompleted() async throws {
        var statusCalls = 0
        let thumbnail = pngData()
        MosaicURLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/jobs":
                let body = #"{"job_id":"job-1","status":"queued","grid":{"width":48,"height":48}}"#
                return (202, 202, Data(body.utf8))
            case "/jobs/job-1":
                statusCalls += 1
                let status = statusCalls >= 2 ? "done" : "processing"
                let progress = statusCalls >= 2 ? 100 : 50
                let body = #"{"job_id":"job-1","status":"\#(status)","progress":\#(progress)}"#
                return (200, 200, Data(body.utf8))
            case "/jobs/job-1/result":
                let body = """
                {"job_id":"job-1","status":"done",
                 "ldr_url":"/artifacts/job-1/model.ldr",
                 "pdf_url":"/artifacts/job-1/instructions.pdf",
                 "parts_url":"/artifacts/job-1/parts.json",
                 "thumbnail_url":"/artifacts/job-1/thumb.png"}
                """
                return (200, 200, Data(body.utf8))
            case "/artifacts/job-1/parts.json":
                let body = #"{"palette_id":"mvp-v1","total_parts":3,"parts":[{"part":"3024","color":"red","qty":3,"ldraw_color":4,"bricklink_color":5,"rebrickable_color":320}]}"#
                return (200, 200, Data(body.utf8))
            case "/artifacts/job-1/thumb.png":
                return (200, 200, thumbnail)
            default:
                return (404, 404, Data())
            }
        }

        let vm = makeViewModel()
        vm.sourceImage = solidImage()
        vm.generate()

        await waitUntil { vm.phase == .completed }

        XCTAssertEqual(vm.phase, .completed)
        XCTAssertEqual(vm.snappedGrid, MosaicJobGrid(width: 48, height: 48))
        XCTAssertEqual(vm.partsList?.totalParts, 3)
        XCTAssertNotNil(vm.result)
        XCTAssertNotNil(vm.thumbnail)
    }

    // MARK: - Error Job

    func testGenerateServerErrorJobFails() async {
        MosaicURLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/jobs":
                let body = #"{"job_id":"job-9","status":"queued","grid":{"width":48,"height":48}}"#
                return (202, 202, Data(body.utf8))
            case "/jobs/job-9":
                let body = #"{"job_id":"job-9","status":"error","message":"render failed"}"#
                return (200, 200, Data(body.utf8))
            default:
                return (404, 404, Data())
            }
        }

        let vm = makeViewModel()
        vm.sourceImage = solidImage()
        vm.generate()

        await waitUntil { if case .failed = vm.phase { return true } else { return false } }

        XCTAssertEqual(vm.errorMessage, "render failed")
    }

    // MARK: - Transport Failure

    func testGenerateUnreachableFails() async {
        MosaicURLProtocolStub.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let vm = makeViewModel()
        vm.sourceImage = solidImage()
        vm.generate()

        await waitUntil { if case .failed = vm.phase { return true } else { return false } }

        XCTAssertEqual(vm.errorMessage, L10n.mosaicErrorUnreachable)
    }

    // MARK: - Derived State

    func testCanGenerateRequiresImage() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.canGenerate)
        vm.sourceImage = solidImage()
        XCTAssertTrue(vm.canGenerate)
    }

    func testProGatingReflectsProvider() {
        XCTAssertTrue(makeViewModel(isPro: true).isProUser)
        XCTAssertFalse(makeViewModel(isPro: false).isProUser)
    }

    func testResetClearsState() {
        let vm = makeViewModel()
        vm.sourceImage = solidImage()
        vm.reset()
        XCTAssertNil(vm.sourceImage)
        XCTAssertEqual(vm.phase, .idle)
    }
}
