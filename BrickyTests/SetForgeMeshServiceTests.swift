import XCTest
@testable import Bricky

final class SetForgeMeshServiceTests: XCTestCase {

    /// Returns queued responses in order (POST create, then GET download).
    private final class QueueHTTPClient: RecognitionHTTPClient, @unchecked Sendable {
        private var responses: [(Data, Int)]
        private let lock = NSLock()
        init(_ responses: [(Data, Int)]) { self.responses = responses }
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            lock.lock(); defer { lock.unlock() }
            let (data, status) = responses.isEmpty ? (Data(), 200) : responses.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }

    private func client(_ responses: [(Data, Int)]) -> AzureTripoMeshClient {
        AzureTripoMeshClient(
            endpoint: URL(string: "https://example.test/api/forgeMeshFromText"),
            httpClient: QueueHTTPClient(responses)
        )
    }

    func testDownloadsSupportedModel() async throws {
        let meta = Data(#"{"modelUrl":"https://x/model.usdz","format":"usdz"}"#.utf8)
        let file = Data("solid usdz bytes".utf8)
        let url = try await client([(meta, 200), (file, 200)])
            .generateMesh(prompt: "a cat", size: .small, entitlementToken: "tok")
        XCTAssertEqual(url.pathExtension, "usdz")
        XCTAssertEqual(try Data(contentsOf: url), file)
    }

    func testUnsupportedFormatThrows() async {
        let meta = Data(#"{"modelUrl":"https://x/model.glb","format":"glb"}"#.utf8)
        await assertThrows(client([(meta, 200)]), expected: .unsupportedFormat("glb"))
    }

    func testNotEntitled() async {
        await assertThrows(client([(Data("{}".utf8), 403)]), expected: .notEntitled)
    }

    func testQuotaExceeded() async {
        await assertThrows(client([(Data("{}".utf8), 429)]), expected: .quotaExceeded)
    }

    func testNotConfiguredWhenNoEndpoint() async {
        await assertThrows(AzureTripoMeshClient(endpoint: nil), expected: .notConfigured)
    }

    private func assertThrows(
        _ client: AzureTripoMeshClient,
        expected: SetForgeMeshError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await client.generateMesh(prompt: "x", size: .small, entitlementToken: "tok")
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as SetForgeMeshError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}
