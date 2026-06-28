import XCTest
@testable import Bricky

/// Tests for the cloud, developer-only AI **set identification** feature: the
/// network client mapping, catalog grounding, and the view-model state machine /
/// gating. Only the network boundary is mocked (`RecognitionHTTPClient`);
/// everything else exercises real code.
@MainActor
final class SetIdentificationTests: XCTestCase {

    // MARK: - Helpers

    private struct StubHTTPClient: RecognitionHTTPClient {
        let result: Result<(Data, URLResponse), Error>
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            try result.get()
        }
    }

    private func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/api/identifySet")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func okBody(candidates: [[String: Any]], remaining: Int = 99) -> Data {
        let json: [String: Any] = ["candidates": candidates, "remainingQuota": remaining]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func client(
        result: Result<(Data, URLResponse), Error>,
        endpoint: URL? = URL(string: "https://example.com/api/identifySet")
    ) -> AzureOpenAISetClient {
        AzureOpenAISetClient(endpoint: endpoint, httpClient: StubHTTPClient(result: result))
    }

    private var sampleImage: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }

    // MARK: - Client mapping

    func testClientDecodesSuccessfulResult() async throws {
        let data = okBody(candidates: [[
            "setNumber": "75192",
            "name": "Millennium Falcon",
            "theme": "Star Wars",
            "year": 2017,
            "confidence": 0.91,
            "summary": "UCS Millennium Falcon."
        ]])
        let svc = client(result: .success((data, httpResponse(200))))
        let result = try await svc.identify(in: sampleImage, entitlementToken: "tok")
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.setNumber, "75192")
        XCTAssertEqual(result.candidates.first?.name, "Millennium Falcon")
        XCTAssertEqual(result.remainingQuota, 99)
    }

    func testClientMaps429ToQuotaExceeded() async {
        let svc = client(result: .success((Data("{}".utf8), httpResponse(429))))
        await assertThrows(svc) { XCTAssertEqual($0, .quotaExceeded) }
    }

    func testClientMaps403ToNotEntitled() async {
        let svc = client(result: .success((Data("{}".utf8), httpResponse(403))))
        await assertThrows(svc) { XCTAssertEqual($0, .notEntitled) }
    }

    func testClientMapsOfflineURLError() async {
        let svc = client(result: .failure(URLError(.notConnectedToInternet)))
        await assertThrows(svc) { XCTAssertEqual($0, .offline) }
    }

    func testClientEmptyCandidatesThrowsNoSetIdentified() async {
        let svc = client(result: .success((okBody(candidates: []), httpResponse(200))))
        await assertThrows(svc) { XCTAssertEqual($0, .noSetIdentified) }
    }

    func testClientNotConfiguredWhenEndpointNil() async {
        let svc = client(result: .success((okBody(candidates: []), httpResponse(200))), endpoint: nil)
        await assertThrows(svc) { XCTAssertEqual($0, .notConfigured) }
    }

    private func assertThrows(
        _ svc: AzureOpenAISetClient,
        _ check: (SetIdentificationError) -> Void
    ) async {
        do {
            _ = try await svc.identify(in: sampleImage, entitlementToken: "tok")
            XCTFail("Expected SetIdentificationError to be thrown")
        } catch let error as SetIdentificationError {
            check(error)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Model decoding leniency

    func testIdentifiedSetDecodesLeniently() throws {
        let json = Data(#"{"name":"Mystery","confidence":2.0}"#.utf8)
        let set = try JSONDecoder().decode(IdentifiedSet.self, from: json)
        XCTAssertEqual(set.setNumber, "")
        XCTAssertEqual(set.confidence, 1.0, accuracy: 0.0001) // clamped
        XCTAssertNil(set.catalogMatch)
        XCTAssertFalse(set.isVerified)
    }

    func testSetIdentificationResultDecodesMissingFields() throws {
        let json = Data(#"{"candidates":[]}"#.utf8)
        let result = try JSONDecoder().decode(SetIdentificationResult.self, from: json)
        XCTAssertTrue(result.isEmpty)
        XCTAssertNil(result.remainingQuota)
    }

    // MARK: - Catalog grounding

    func testCatalogResolvesKnownSetByNumber() {
        // 75192 (Millennium Falcon) ships in the bundled reference catalog.
        let match = LegoSetCatalog.shared.resolve(setNumber: "75192")
        XCTAssertEqual(match?.setNumber, "75192")
    }

    func testCatalogNormalizesVariantSuffix() {
        XCTAssertEqual(LegoSetCatalog.normalizeSetNumber("75192-1"), "75192")
        let match = LegoSetCatalog.shared.resolve(setNumber: "75192-1")
        XCTAssertEqual(match?.setNumber, "75192")
    }

    func testCatalogResolvesByNameWhenNumberUnknown() {
        let match = LegoSetCatalog.shared.resolve(setNumber: "000000", name: "Millennium Falcon")
        XCTAssertEqual(match?.setNumber, "75192")
    }

    func testCatalogReturnsNilForUnknownSet() {
        XCTAssertNil(LegoSetCatalog.shared.resolve(setNumber: "999999", name: "Totally Made Up Set"))
    }

    // MARK: - View-model grounding & ranking

    func testGroundingVerifiesAndRanksCandidates() {
        let vm = SetIdentificationViewModel(service: NeverCalledSetService())
        let candidates = [
            IdentifiedSet(setNumber: "999999", name: "Made Up", confidence: 0.95, summary: ""),
            IdentifiedSet(setNumber: "75192", name: "Millennium Falcon", confidence: 0.40, summary: "")
        ]
        let grounded = vm.groundedCandidates(from: candidates)
        // Verified catalog match ranks first even with lower confidence.
        XCTAssertEqual(grounded.first?.setNumber, "75192")
        XCTAssertTrue(grounded.first?.isVerified ?? false)
        XCTAssertFalse(grounded.last?.isVerified ?? true)
        // Verified candidate uses authoritative catalog name.
        XCTAssertEqual(grounded.first?.displayName, "Millennium Falcon")
        XCTAssertNotNil(grounded.first?.pieceCount)
    }
}

/// View-model gating tests on the real `SubscriptionManager` singleton (only the
/// developer override is toggled), proving the developer-only gating and
/// honest-failure paths without any StoreKit receipt.
@MainActor
final class SetIdentificationViewModelTests: XCTestCase {

    private var savedOverride = false

    override func setUp() {
        super.setUp()
        savedOverride = SubscriptionManager.shared.developerProOverride
    }

    override func tearDown() {
        SubscriptionManager.shared.developerProOverride = savedOverride
        super.tearDown()
    }

    private var sampleImage: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    func testNonDeveloperGetsUpsell() async {
        SubscriptionManager.shared.developerProOverride = false
        let vm = SetIdentificationViewModel(service: NeverCalledSetService())
        vm.setImage(sampleImage)
        await vm.identify()
        XCTAssertEqual(vm.phase, .upsell)
        XCTAssertTrue(vm.requiresUpgrade)
    }

    func testDeveloperOverrideSendsDevBypassTokenAndGroundsResults() async {
        SubscriptionManager.shared.developerProOverride = true
        guard SubscriptionManager.shared.aiRecognitionsRemaining > 0 else { return }
        let service = TokenCapturingSetService(
            result: SetIdentificationResult(
                candidates: [
                    IdentifiedSet(setNumber: "75192", name: "Millennium Falcon",
                                  theme: "Star Wars", year: 2017,
                                  confidence: 0.9, summary: "UCS.")
                ],
                remainingQuota: 50
            )
        )
        let vm = SetIdentificationViewModel(service: service)
        vm.setImage(sampleImage)
        await vm.identify()
        let captured = await service.token()
        XCTAssertEqual(captured, AppConfig.aiRecognitionDevBypassToken)
        if case .results(let sets) = vm.phase {
            XCTAssertEqual(sets.first?.setNumber, "75192")
            XCTAssertTrue(sets.first?.isVerified ?? false)
        } else {
            XCTFail("Expected .results, got \(vm.phase)")
        }
    }

    func testIdentifyNoOpsWithoutImage() async {
        let vm = SetIdentificationViewModel(service: NeverCalledSetService())
        await vm.identify()
        XCTAssertEqual(vm.phase, .idle)
    }
}

// MARK: - Test doubles

private struct NeverCalledSetService: SetIdentificationService {
    func identify(in image: UIImage, entitlementToken: String) async throws -> SetIdentificationResult {
        XCTFail("Service must not be called when gating blocks the request")
        return SetIdentificationResult(candidates: [])
    }
}

private actor TokenCapturingSetService: SetIdentificationService {
    private(set) var capturedToken: String?
    private let result: SetIdentificationResult
    init(result: SetIdentificationResult) { self.result = result }
    func identify(in image: UIImage, entitlementToken: String) async throws -> SetIdentificationResult {
        capturedToken = entitlementToken
        return result
    }
    func token() -> String? { capturedToken }
}
