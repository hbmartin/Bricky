import SwiftUI
import UIKit

/// Drives the AI subject recognition flow: pick a photo → (developer-only,
/// quota-
/// limited) recognize celebrities, cartoon characters, famous landmarks/places,
/// musicians, etc. via the cloud proxy.
///
/// Offline-first contract: this is an explicitly cloud feature, so when there's
/// no network it reports an honest "requires connection" state rather than
/// fabricating results. Free users are never offered a call — they see an
/// upsell. The server proxy is the source of truth for entitlement + quota.
@MainActor
final class ImageRecognitionViewModel: ObservableObject {

    /// One honest state at a time.
    enum Phase: Equatable {
        case idle
        case recognizing
        case results([RecognizedSubject])
        case empty
        case failed(String)
        /// Free user — show the paywall upsell instead of running a call.
        case upsell
    }

    @Published var sourceImage: UIImage?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remainingThisMonth: Int

    private let service: ImageRecognitionService
    private let subscriptions: SubscriptionManager

    init(
        service: ImageRecognitionService = AzureOpenAIRecognitionClient(),
        subscriptions: SubscriptionManager = .shared
    ) {
        self.service = service
        self.subscriptions = subscriptions
        self.remainingThisMonth = subscriptions.aiRecognitionsRemaining
    }

    /// True when the developer override is on and quota remains.
    var canRecognize: Bool {
        subscriptions.canUseAIRecognition && sourceImage != nil
    }

    /// True for anyone without the developer override — cloud AI is a hidden,
    /// developer-only feature, so normal users never reach a run button.
    var requiresUpgrade: Bool {
        !subscriptions.developerProOverride
    }

    /// True for the developer once the monthly safety cap is reached.
    var quotaExhausted: Bool {
        subscriptions.developerProOverride && subscriptions.aiRecognitionsRemaining == 0
    }

    func setImage(_ image: UIImage?) {
        sourceImage = image
        if case .results = phase { phase = .idle }
        if case .empty = phase { phase = .idle }
        if case .failed = phase { phase = .idle }
    }

    func refreshQuota() {
        remainingThisMonth = subscriptions.aiRecognitionsRemaining
    }

    func recognize() async {
        guard let image = sourceImage else { return }

        guard subscriptions.developerProOverride else {
            phase = .upsell
            return
        }
        guard subscriptions.aiRecognitionsRemaining > 0 else {
            phase = .failed(ImageRecognitionError.quotaExceeded.localizedDescription)
            return
        }
        guard let token = await subscriptions.recognitionEntitlementToken() else {
            // Developer override on but no configured dev-bypass token — the
            // proxy can't verify this, so don't burn budget. Honest message.
            phase = .failed(ImageRecognitionError.notEntitled.localizedDescription)
            return
        }

        phase = .recognizing
        do {
            let result = try await service.recognize(in: image, entitlementToken: token)
            subscriptions.recordAIRecognition()
            refreshQuota()
            if result.isEmpty {
                phase = .empty
            } else {
                phase = .results(result.subjects)
            }
        } catch let error as ImageRecognitionError {
            if case .noSubjectsFound = error {
                phase = .empty
            } else {
                phase = .failed(error.localizedDescription)
            }
        } catch {
            phase = .failed(ImageRecognitionError.server(status: -1, message: nil).localizedDescription)
        }
    }
}
