import Foundation

/// Central configuration for all app identity and branding.
///
/// **Every** string that references the app name, bundle ID, or any
/// app-specific identifier must read from this enum. This makes it
/// trivial to rebrand the app — change these values and rebuild.
///
/// Usage:
///   `AppConfig.appName`          → "Bricky"
///   `AppConfig.bundleId`         → "com.bricky.app"
///   `"\(AppConfig.queuePrefix).pipeline"` → "com.bricky.pipeline"
enum AppConfig {
    // MARK: - Identity

    /// User-visible app name (navigation titles, onboarding, share text, etc.)
    static let appName = "Bricky"

    /// Reverse-DNS bundle identifier for the main app target.
    static let bundleId = "com.bricky.app"

    /// Custom URL scheme for deep links and OAuth redirects.
    static let urlScheme = "bricky"

    /// Full OAuth redirect URL.
    static let authRedirectURL = "\(urlScheme)://auth"

    // MARK: - iCloud

    /// iCloud container identifier (must match entitlements).
    static let iCloudContainer = "iCloud.\(bundleId)"

    /// Ubiquity KV store identifier pattern.
    static let kvStoreId = "$(TeamIdentifierPrefix)\(bundleId)"

    // MARK: - Storage Prefixes

    /// Prefix for keychain service identifiers.
    static let keychainPrefix = "com.bricky"

    /// Prefix for GCD dispatch queue labels.
    static let queuePrefix = "com.bricky"

    /// Prefix for UserDefaults keys.
    static let defaultsPrefix = "bricky"

    /// URLCache on-disk directory name.
    static let urlCachePath = "AppURLCache"

    // MARK: - In-App Purchase

    /// Bricky Pro product ID. A single one-time (non-consumable) unlock —
    /// there is no subscription.
    static let iapProProductId = "\(bundleId).pro"

    // MARK: - AI Subject Recognition (cloud, developer-only)

    /// Base URL of the server proxy that holds the Azure OpenAI key, verifies
    /// the developer-bypass token, enforces the monthly quota, and calls GPT-4o
    /// vision. The key is NEVER shipped in the app — the proxy is the only place
    /// that can reach Azure OpenAI. Cloud AI is a hidden, developer-only feature
    /// (unlocked by the in-app override); no normal user can reach it.
    /// Overridable at runtime via the `BRICKY_RECOGNITION_ENDPOINT` Info.plist
    /// value / environment.
    static var aiRecognitionEndpoint: URL? {
        if let raw = infoPlistString("BRICKY_RECOGNITION_ENDPOINT") ??
            ProcessInfo.processInfo.environment["BRICKY_RECOGNITION_ENDPOINT"],
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://\(appName.lowercased())-recognition.azurewebsites.net/api/recognizeImage")
    }

    /// Monthly AI recognition allowance. Cloud AI is developer-only, so this is
    /// just a safety cap on the developer's own Azure GPT-4o spend; it keeps
    /// total spend under the development cost cap while testing. Everyone without
    /// the developer override gets zero.
    static let proMonthlyAIRecognitionLimit = 100

    /// Developer-bypass entitlement token for AI recognition. When Pro is
    /// granted via the in-app developer override (the 7-tap toggle), there is
    /// no real StoreKit receipt to send the proxy, so the app instead sends
    /// this `dev-override:<secret>` token. The proxy ONLY honors it when its
    /// `DEV_BYPASS_TOKEN` app setting matches the `<secret>` portion — and that
    /// setting is left UNSET in production, so this path is inert there.
    ///
    /// Overridable at runtime via the `BRICKY_RECOGNITION_DEV_TOKEN` Info.plist
    /// value / environment. The baked secret must match the proxy's
    /// `DEV_BYPASS_TOKEN` app setting (see services/recognition-proxy/README).
    static var aiRecognitionDevBypassToken: String? {
        if let raw = infoPlistString("BRICKY_RECOGNITION_DEV_TOKEN") ??
            ProcessInfo.processInfo.environment["BRICKY_RECOGNITION_DEV_TOKEN"],
           !raw.isEmpty {
            return raw
        }
        return "dev-override:8f3c2a9e7b14d05f96a1c3e8d2b47f60"
    }

    private static func infoPlistString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    // MARK: - Keychain Keys (derived from prefix)

    static let keychainAccount = defaultsPrefix

    // MARK: - Dispatch Queues

    static let pipelineQueue = "\(queuePrefix).pipeline"
    static let environmentMonitorQueue = "\(queuePrefix).environmentmonitor"
    static let ldrawQueue = "\(queuePrefix).ldraw"
    static let pieceImageQueue = "\(queuePrefix).pieceimage"
    static let performanceQueue = "\(queuePrefix).performance"
    static let correctionLoggerQueue = "\(queuePrefix).correctionlogger"

    // MARK: - UserDefaults Keys

    static let dailyScanCountKey = "\(defaultsPrefix).daily.scanCount"
    static let dailyScanDateKey = "\(defaultsPrefix).daily.scanDate"
    static let analyticsEnabledKey = "\(defaultsPrefix).analytics.enabled"
    static let developerProOverrideKey = "\(defaultsPrefix).developer.proOverride"

    /// Count of AI subject recognitions used in the current calendar month.
    static let aiRecognitionCountKey = "\(defaultsPrefix).ai.recognitionCount"

    /// First-day-of-month marker (yyyy-MM) the count above belongs to, so it
    /// resets automatically when the month rolls over.
    static let aiRecognitionMonthKey = "\(defaultsPrefix).ai.recognitionMonth"

    // MARK: - Notifications

    static let minifigureScanCompletedNotification = "\(appName).minifigureScanCompleted"

    // MARK: - Display

    /// Hashtag for sharing (no spaces, lowercase).
    static let hashtag = "#\(appName.lowercased())"

    /// Privacy policy URL (if hosted).
    static let privacyPolicyURL = "https://\(appName.lowercased()).app/privacy"

    /// Support email.
    static let supportEmail = "support@\(appName.lowercased()).app"
}