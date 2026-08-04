import Foundation

/// A cloud vision second opinion on one explicitly consented frame
/// (ADR 0011). Implementations receive exactly one JPEG plus minimal step
/// context and return a verdict constrained to the local grammar's enum.
protocol CloudVisionProvider: Sendable {
    func secondOpinion(boardJPEG: Data, context: CloudAssistContext) async throws -> CloudAssistOpinion
}

/// Direct device-to-API Claude client. There is deliberately no SDK, no
/// server, no relay, and no retry queue: one request per consented frame,
/// authenticated with the user's own key from the Keychain.
struct ClaudeVisionProvider: CloudVisionProvider {
    /// Pinned at implementation per the plan: the latest vision-capable
    /// Claude model. Adaptive thinking is on by default on this model, so
    /// no `thinking` parameter is sent, and `max_tokens` includes headroom
    /// for thinking ahead of the small structured verdict.
    static let model = "claude-opus-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    /// Injectable transport so tests exercise request building and response
    /// parsing without a network.
    var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    func secondOpinion(boardJPEG: Data, context: CloudAssistContext) async throws -> CloudAssistOpinion {
        guard let apiKey = CloudAssistKeyStore.load() else { throw CloudAssistError.missingKey }
        let request = try Self.makeRequest(apiKey: apiKey, boardJPEG: boardJPEG, context: context)
        let (data, _) = try await transport(request)
        return try Self.parse(responseBody: data)
    }

    // MARK: - Request

    static func makeRequest(apiKey: String, boardJPEG: Data, context: CloudAssistContext) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body(boardJPEG: boardJPEG, context: context))
        return request
    }

    static func body(boardJPEG: Data, context: CloudAssistContext) -> [String: Any] {
        let prompt = """
        The top image is a photo of a physical brick build. Candidate A is a \
        render of the cumulative authored target for step \(context.stepIndex) \
        of \(context.stepCount). Decide whether the physical build matches the \
        target: complete, incomplete, or uncertain. Prefer uncertain over \
        guessing; a wrong "complete" is the worst outcome. Do not diagnose \
        individual missing parts. Give a one-sentence rationale.
        """
        // The schema mirrors the local grammar exactly (`result` over the
        // same enum), so both providers decode into StepCheckResult.
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "result": [
                    "type": "string",
                    "enum": StepCheckResult.allCases.map(\.rawValue),
                ],
                "rationale": ["type": "string"],
            ],
            "required": ["result", "rationale"],
            "additionalProperties": false,
        ]
        return [
            "model": model,
            "max_tokens": 4096,
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": boardJPEG.base64EncodedString(),
                        ],
                    ],
                    ["type": "text", "text": prompt],
                ],
            ]],
        ]
    }

    // MARK: - Response

    private struct MessageResponse: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
        struct APIError: Decodable {
            let message: String
        }
        let type: String
        let content: [ContentBlock]?
        let stopReason: String?
        let error: APIError?

        enum CodingKeys: String, CodingKey {
            case type, content, error
            case stopReason = "stop_reason"
        }
    }

    private struct StructuredVerdict: Decodable {
        let result: String
        let rationale: String
    }

    static func parse(responseBody: Data) throws -> CloudAssistOpinion {
        let message: MessageResponse
        do {
            message = try JSONDecoder().decode(MessageResponse.self, from: responseBody)
        } catch {
            throw CloudAssistError.invalidResponse("undecodable body")
        }
        if message.type == "error" {
            throw CloudAssistError.api(message.error?.message ?? "The cloud request failed.")
        }
        // A refusal is HTTP 200 with empty or partial content — it must be
        // checked before reading content.
        if message.stopReason == "refusal" {
            throw CloudAssistError.refused
        }
        guard let text = message.content?.first(where: { $0.type == "text" })?.text,
              let payload = text.data(using: .utf8),
              let verdict = try? JSONDecoder().decode(StructuredVerdict.self, from: payload)
        else {
            throw CloudAssistError.invalidResponse("no structured verdict in content")
        }
        return CloudAssistOpinion(
            verdict: StepCheckResult(rawValue: verdict.result) ?? .uncertain,
            rationale: verdict.rationale
        )
    }
}
