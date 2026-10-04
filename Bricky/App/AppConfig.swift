import Foundation

enum AppConfig {
    static let appName = "Bricky"
    static let bundleID = "com.bricky.app"
    static let queuePrefix = "com.bricky"
    static let applicationSupportNamespace = InstructionModelImporter.namespace
    /// The development-time semantic oracle version recorded in benchmark rows.
    static let pyldraw3Version = "1.5.0"

    /// UserDefaults keys for the developer evidence controls (ADR 0007)
    /// and the opt-in cloud assist toggle (ADR 0011).
    enum Defaults {
        static let evidenceCaptureEnabled = "developer.evidenceCaptureEnabled"
        static let corpusCollectionEnabled = "developer.corpusCollectionEnabled"
        static let cloudAssistEnabled = "cloudAssist.enabled"
        /// Persisted so a user who allowed a 3 GB cellular download is not
        /// silently refused after a relaunch.
        static let allowsCellularModelDownload = "recoveryModel.allowsCellularDownload"
        /// Developer A/B arms for the VLM path (ADR 0010 amendment).
        static let inferenceArmPlan = "developer.inferenceArmPlan"
        static let inferenceArmCounter = "developer.inferenceArmCounter"
        /// Unload the VLM after `RecoveryModelManager.idleUnloadInterval`
        /// without inference. Off by default: re-warming costs a load.
        static let idleUnloadEnabled = "developer.idleUnloadEnabled"
    }
}
