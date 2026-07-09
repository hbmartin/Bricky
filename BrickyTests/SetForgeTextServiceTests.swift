import XCTest
@testable import Bricky

final class SetForgeTextServiceTests: XCTestCase {

    private struct StubHTTPClient: RecognitionHTTPClient {
        let data: Data
        let status: Int
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
    }

    private func client(json: String, status: Int = 200) -> AzureOpenAIForgeTextClient {
        AzureOpenAIForgeTextClient(
            endpoint: URL(string: "https://example.test/api/forgeFromText"),
            httpClient: StubHTTPClient(data: Data(json.utf8), status: status)
        )
    }

    func testDecodesVoxelModel() async throws {
        let json = """
        {"width":2,"height":1,"depth":1,"subject":"cube",
         "voxels":[{"x":0,"y":0,"z":0,"color":"Red"},{"x":1,"y":0,"z":0,"color":"Blue"}]}
        """
        let model = try await client(json: json).generateModel(
            prompt: "a cube", size: .small, entitlementToken: "tok"
        )
        XCTAssertEqual(model.voxels.count, 2)
        XCTAssertEqual(model.source, .text)
        XCTAssertEqual(model.subject, "cube")
        XCTAssertTrue(model.voxels.contains { $0.color == .red })
        XCTAssertTrue(model.voxels.contains { $0.color == .blue })
    }

    func testUnknownColorsAreDropped() async throws {
        let json = """
        {"width":2,"height":1,"depth":1,"subject":"x",
         "voxels":[{"x":0,"y":0,"z":0,"color":"Red"},{"x":1,"y":0,"z":0,"color":"Rainbow"}]}
        """
        let model = try await client(json: json).generateModel(
            prompt: "x", size: .small, entitlementToken: "tok"
        )
        XCTAssertEqual(model.voxels.count, 1, "Unknown colour voxel should be dropped")
    }

    func testNotEntitledStatus() async {
        let c = client(json: "{}", status: 403)
        await assertThrows(c, expected: .notEntitled)
    }

    func testQuotaExceededStatus() async {
        await assertThrows(client(json: "{}", status: 429), expected: .quotaExceeded)
    }

    func testEmptyModelStatus() async {
        await assertThrows(client(json: "{}", status: 422), expected: .emptyModel)
    }

    func testNotConfiguredWhenNoEndpoint() async {
        let c = AzureOpenAIForgeTextClient(endpoint: nil)
        await assertThrows(c, expected: .notConfigured)
    }

    private func assertThrows(
        _ client: AzureOpenAIForgeTextClient,
        expected: SetForgeTextError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await client.generateModel(prompt: "x", size: .small, entitlementToken: "tok")
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as SetForgeTextError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}
