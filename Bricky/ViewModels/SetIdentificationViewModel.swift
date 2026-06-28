import SwiftUI
import UIKit

/// Drives the AI LEGO **set** identification flow: pick or capture a photo of a
/// built model → (developer-only, quota-limited) identify which official set it
/// is via the cloud proxy, then ground each proposal against `LegoSetCatalog`.
///
/// Offline-first contract: this is an explicitly cloud feature, so with no
/// network it reports an honest "requires connection" state rather than
/// fabricating results. Normal users never reach a run button — they see an
/// upsell. The server proxy is the source of truth for entitlement + quota.
@MainActor
final class SetIdentificationViewModel: ObservableObject {

    /// One honest state at a time.
    enum Phase: Equatable {
        case idle
        case identifying
        case results([IdentifiedSet])
        case empty
        case failed(String)
        /// Non-developer user — show the gated/upsell card instead of a call.
        case upsell
    }

    @Published var sourceImage: UIImage?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remainingThisMonth: Int

    private let service: SetIdentificationService
    private let subscriptions: SubscriptionManager
    private let catalog: LegoSetCatalog

    init(
        service: SetIdentificationService = AzureOpenAISetClient(),
        subscriptions: SubscriptionManager = .shared,
        catalog: LegoSetCatalog = .shared
    ) {
        self.service = service
        self.subscriptions = subscriptions
        self.catalog = catalog
        self.remainingThisMonth = subscriptions.aiRecognitionsRemaining
    }

    /// True when the developer override is on, quota remains, and a photo is set.
    var canIdentify: Bool {
        subscriptions.canIdentifySets && sourceImage != nil
    }

    /// True for anyone without the developer override — set identification is a
    /// hidden, developer-only feature, so normal users never reach a run button.
    var requiresUpgrade: Bool {
        !subscriptions.developerProOverride
    }

    /// True for the developer once the monthly safety cap is reached.
    var quotaExhausted: Bool {
        subscriptions.developerProOverride && subscriptions.aiRecognitionsRemaining == 0
    }

    func setImage(_ image: UIImage?) {
        sourceImage = image
        switch phase {
        case .results, .empty, .failed:
            phase = .idle
        default:
            break
        }
    }

    func refreshQuota() {
        remainingThisMonth = subscriptions.aiRecognitionsRemaining
    }

    func identify() async {
        guard let image = sourceImage else { return }

        guard subscriptions.developerProOverride else {
            phase = .upsell
            return
        }
        guard subscriptions.aiRecognitionsRemaining > 0 else {
            phase = .failed(SetIdentificationError.quotaExceeded.localizedDescription)
            return
        }
        guard let token = await subscriptions.recognitionEntitlementToken() else {
            // Developer override on but no configured dev-bypass token — the
            // proxy can't verify this, so don't burn budget. Honest message.
            phase = .failed(SetIdentificationError.notEntitled.localizedDescription)
            return
        }

        phase = .identifying
        do {
            let result = try await service.identify(in: image, entitlementToken: token)
            subscriptions.recordAIRecognition()
            refreshQuota()
            let grounded = groundedCandidates(from: result.candidates)
            if grounded.isEmpty {
                phase = .empty
            } else {
                phase = .results(grounded)
            }
        } catch let error as SetIdentificationError {
            if case .noSetIdentified = error {
                phase = .empty
            } else {
                phase = .failed(error.localizedDescription)
            }
        } catch {
            phase = .failed(SetIdentificationError.server(status: -1, message: nil).localizedDescription)
        }
    }

    /// Grounds each AI proposal against the reference catalog and ranks results:
    /// verified matches first, then by descending confidence. Unverified guesses
    /// are kept (the catalog is not exhaustive) but flagged so the UI never
    /// presents them as confirmed fact.
    func groundedCandidates(from candidates: [IdentifiedSet]) -> [IdentifiedSet] {
        candidates
            .map { candidate in
                let match = catalog.resolve(
                    setNumber: candidate.setNumber,
                    name: candidate.name,
                    year: candidate.year
                )
                return candidate.grounded(with: match)
            }
            .sorted { lhs, rhs in
                if lhs.isVerified != rhs.isVerified {
                    return lhs.isVerified && !rhs.isVerified
                }
                return lhs.confidence > rhs.confidence
            }
    }
}
