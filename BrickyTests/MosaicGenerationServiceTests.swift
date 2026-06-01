import XCTest
@testable import Bricky

// MARK: - MosaicGenerationService Tests
//
// Drives the backend HTTP client against a stubbed URLProtocol so no live
// server is required. Covers:
//   1. Multipart submit → MosaicJobCreation decoding (HTTP 202)
//   2. Status / result decoding (snake_case → camelCase)
//   3. Error mapping (transport → .unreachable, non-2xx → .server w/ detail)
//   4. Relative artifact URL resolution against the base URL
//   5. Parts-list artifact decoding

final class MosaicGenerationServiceTests: XCTestCase {

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

    private func solidImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    // MARK: - Submit

    func testSubmitJobDecodesCreation() async throws {
        let json = """
        {"job_id": "job-123", "status": "queued", "grid": {"width": 48, "height": 48}}
        """
        MosaicURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/jobs")
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            return (202, 202, Data(json.utf8))
        }

        let service = makeService()
        let creation = try await service.submitJob(image: solidImage(), width: 48, height: 48)

        XCTAssertEqual(creation.jobId, "job-123")
        XCTAssertEqual(creation.status, .queued)
        XCTAssertEqual(creation.grid, MosaicJobGrid(width: 48, height: 48))
    }

    func testSubmitJobWrongStatusMapsToServerError() async {
        let json = #"{"detail": "Unsupported palette"}"#
        MosaicURLProtocolStub.handler = { _ in (400, 400, Data(json.utf8)) }

        let service = makeService()
        do {
            _ = try await service.submitJob(image: solidImage(), width: 48, height: 48)
            XCTFail("Expected server error")
        } catch let error as MosaicGenerationService.ServiceError {
            XCTAssertEqual(error, .server(status: 400, message: "Unsupported palette"))
            XCTAssertEqual(error.errorDescription, "Unsupported palette")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Status

    func testJobStatusDecodesProgress() async throws {
        let json = #"{"job_id": "job-1", "status": "processing", "progress": 42}"#
        MosaicURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/jobs/job-1")
            return (200, 200, Data(json.utf8))
        }

        let service = makeService()
        let progress = try await service.jobStatus(id: "job-1")
        XCTAssertEqual(progress.status, .processing)
        XCTAssertEqual(progress.percent, 42)
    }

    func testJobStatusDonePercentIs100() async throws {
        let json = #"{"job_id": "job-1", "status": "done"}"#
        MosaicURLProtocolStub.handler = { _ in (200, 200, Data(json.utf8)) }

        let service = makeService()
        let progress = try await service.jobStatus(id: "job-1")
        XCTAssertEqual(progress.percent, 100)
    }

    // MARK: - Result

    func testJobResultDecodesArtifactURLs() async throws {
        let json = """
        {"job_id": "job-1", "status": "done",
         "ldr_url": "/artifacts/job-1/model.ldr",
         "pdf_url": "/artifacts/job-1/instructions.pdf",
         "parts_url": "/artifacts/job-1/parts.json",
         "thumbnail_url": "/artifacts/job-1/thumb.png"}
        """
        MosaicURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/jobs/job-1/result")
            return (200, 200, Data(json.utf8))
        }

        let service = makeService()
        let result = try await service.jobResult(id: "job-1")
        XCTAssertEqual(result.ldrURL, "/artifacts/job-1/model.ldr")
        XCTAssertEqual(result.partsURL, "/artifacts/job-1/parts.json")
    }

    // MARK: - URL Resolution

    func testResolveRelativeURL() {
        let service = makeService()
        let resolved = service.resolve("/artifacts/job-1/model.ldr")
        XCTAssertEqual(resolved?.absoluteString, "https://mosaic.test/artifacts/job-1/model.ldr")
    }

    func testResolveAbsoluteURL() {
        let service = makeService()
        let resolved = service.resolve("https://cdn.example.com/a.ldr")
        XCTAssertEqual(resolved?.absoluteString, "https://cdn.example.com/a.ldr")
    }

    // MARK: - Parts List

    func testFetchPartsListDecodes() async throws {
        let result = MosaicJobResult(
            jobId: "job-1",
            status: .done,
            ldrURL: "/artifacts/job-1/model.ldr",
            pdfURL: "/artifacts/job-1/instructions.pdf",
            partsURL: "/artifacts/job-1/parts.json",
            thumbnailURL: "/artifacts/job-1/thumb.png"
        )
        let json = """
        {"palette_id": "mvp-v1", "total_parts": 5, "parts": [
           {"part": "3024", "color": "red", "qty": 3,
            "ldraw_color": 4, "bricklink_color": 5, "rebrickable_color": 320},
           {"part": "3023", "color": "blue", "qty": 2,
            "ldraw_color": 1, "bricklink_color": 7, "rebrickable_color": 1}
        ]}
        """
        MosaicURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/artifacts/job-1/parts.json")
            return (200, 200, Data(json.utf8))
        }

        let service = makeService()
        let parts = try await service.fetchPartsList(from: result)
        XCTAssertEqual(parts.paletteId, "mvp-v1")
        XCTAssertEqual(parts.totalParts, 5)
        XCTAssertEqual(parts.parts.count, 2)
        XCTAssertEqual(parts.parts[0].id, "3024-red")
    }

    // MARK: - Transport Failure

    func testTransportFailureMapsToUnreachable() async {
        MosaicURLProtocolStub.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let service = makeService()
        do {
            _ = try await service.jobStatus(id: "job-1")
            XCTFail("Expected unreachable error")
        } catch let error as MosaicGenerationService.ServiceError {
            XCTAssertEqual(error, .unreachable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - URLProtocol Stub

/// Minimal `URLProtocol` that returns canned responses for the mosaic client.
/// The handler returns `(statusCode, ignored, body)` — the middle value is
/// unused but kept for readability at call sites describing the "expected"
/// status alongside the actual one.
final class MosaicURLProtocolStub: URLProtocol {

    /// `(actualStatusCode, expectedStatusCode, body)`; may throw to simulate a
    /// transport failure.
    static var handler: ((URLRequest) throws -> (Int, Int, Data))?

    static func reset() { handler = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, _, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
