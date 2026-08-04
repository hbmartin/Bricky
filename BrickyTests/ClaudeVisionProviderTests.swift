import XCTest
@testable import Bricky

final class ClaudeVisionProviderTests: XCTestCase {
    // MARK: - Request building

    func testRequestCarriesAuthHeadersAndEndpoint() throws {
        let request = try ClaudeVisionProvider.makeRequest(
            apiKey: "sk-ant-test",
            boardJPEG: Data([0xFF, 0xD8]),
            context: .init(stepIndex: 3, stepCount: 9)
        )
        XCTAssertEqual(request.url, ClaudeVisionProvider.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testBodyPinsModelAndMirrorsLocalGrammarEnum() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF])
        let body = ClaudeVisionProvider.body(
            boardJPEG: jpeg,
            context: .init(stepIndex: 2, stepCount: 5)
        )
        XCTAssertEqual(body["model"] as? String, "claude-opus-5")

        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let resultProperty = try XCTUnwrap(properties["result"] as? [String: Any])
        XCTAssertEqual(
            Set(try XCTUnwrap(resultProperty["enum"] as? [String])),
            Set(StepCheckResult.allCases.map(\.rawValue))
        )

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        let image = try XCTUnwrap(content.first { $0["type"] as? String == "image" })
        let source = try XCTUnwrap(image["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, jpeg.base64EncodedString())
        let text = try XCTUnwrap(content.first { $0["type"] as? String == "text" })
        let prompt = try XCTUnwrap(text["text"] as? String)
        XCTAssertTrue(prompt.contains("step 2"))
        XCTAssertTrue(prompt.contains("of 5"))
    }

    // MARK: - Response parsing

    func testParsesStructuredVerdictFromTextBlock() throws {
        let body = """
        {"type":"message","stop_reason":"end_turn","content":[
          {"type":"thinking","thinking":""},
          {"type":"text","text":"{\\"result\\":\\"incomplete\\",\\"rationale\\":\\"Top layer missing.\\"}"}
        ]}
        """
        let opinion = try ClaudeVisionProvider.parse(responseBody: Data(body.utf8))
        XCTAssertEqual(opinion.verdict, .incomplete)
        XCTAssertEqual(opinion.rationale, "Top layer missing.")
    }

    func testRefusalStopReasonThrowsBeforeReadingContent() {
        let body = """
        {"type":"message","stop_reason":"refusal","content":[]}
        """
        XCTAssertThrowsError(try ClaudeVisionProvider.parse(responseBody: Data(body.utf8))) { error in
            XCTAssertEqual(error as? CloudAssistError, .refused)
        }
    }

    func testErrorEnvelopeSurfacesAPIMessage() {
        let body = """
        {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
        """
        XCTAssertThrowsError(try ClaudeVisionProvider.parse(responseBody: Data(body.utf8))) { error in
            XCTAssertEqual(error as? CloudAssistError, .api("invalid x-api-key"))
        }
    }

    func testMissingStructuredVerdictThrowsInvalidResponse() {
        let body = """
        {"type":"message","stop_reason":"end_turn","content":[{"type":"text","text":"not json"}]}
        """
        XCTAssertThrowsError(try ClaudeVisionProvider.parse(responseBody: Data(body.utf8))) { error in
            guard case .invalidResponse = error as? CloudAssistError else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    func testUnknownVerdictValueMapsToUncertain() throws {
        // Defensive only: the schema constrains the enum server-side, but a
        // drifted value must never decode as anything stronger.
        let body = """
        {"type":"message","stop_reason":"end_turn","content":[
          {"type":"text","text":"{\\"result\\":\\"mostly-done\\",\\"rationale\\":\\"drift\\"}"}
        ]}
        """
        let opinion = try ClaudeVisionProvider.parse(responseBody: Data(body.utf8))
        XCTAssertEqual(opinion.verdict, .uncertain)
    }

    // MARK: - Transport integration

    func testSecondOpinionWithoutStoredKeyThrowsMissingKey() async {
        CloudAssistKeyStore.delete()
        let provider = ClaudeVisionProvider(transport: { _ in
            XCTFail("no request may be made without a key")
            throw CloudAssistError.invalidResponse("unreachable")
        })
        do {
            _ = try await provider.secondOpinion(
                boardJPEG: Data([0xFF]),
                context: .init(stepIndex: 1, stepCount: 1)
            )
            XCTFail("expected missingKey")
        } catch {
            XCTAssertEqual(error as? CloudAssistError, .missingKey)
        }
    }
}
