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

    /// Monthly subscription product ID.
    static let iapMonthlyProductId = "\(bundleId).pro.monthly"

    /// Annual subscription product ID.
    static let iapAnnualProductId = "\(bundleId).pro.annual"

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

    // MARK: - Notifications

    static let minifigureScanCompletedNotification = "\(appName).minifigureScanCompleted"

    // MARK: - Display

    /// Hashtag for sharing (no spaces, lowercase).
    static let hashtag = "#\(appName.lowercased())"

    /// Privacy policy URL (if hosted).
    static let privacyPolicyURL = "https://\(appName.lowercased()).app/privacy"

    /// Support email.
    static let supportEmail = "support@\(appName.lowercased()).app"

    // MARK: - LEGO Mosaic Backend

    /// Base URL for the LEGO Model Generation backend
    /// (`services/lego-model-gen`).
    ///
    /// Resolution order (most → least specific):
    /// 1. UserDefaults key `bricky.mosaic.apiBaseURL` (settable for QA/dev).
    /// 2. Environment variable `BRICKY_MOSAIC_API_URL`.
    /// 3. Local default `http://localhost:8000` — the backend is not yet
    ///    deployed, so out of the box the client reports an honest
    ///    "can't reach the service" error rather than pretending to work.
    static var mosaicApiBaseURL: URL {
        let key = "\(defaultsPrefix).mosaic.apiBaseURL"
        if let stored = UserDefaults.standard.string(forKey: key),
           let url = URL(string: stored) {
            return url
        }
        if let env = ProcessInfo.processInfo.environment["BRICKY_MOSAIC_API_URL"],
           let url = URL(string: env) {
            return url
        }
        return URL(string: "http://localhost:8000")!
    }

    /// Hard cap on uploaded source-image size, mirroring the backend's
    /// 20 MB request limit.
    static let mosaicMaxUploadBytes = 20 * 1024 * 1024
}