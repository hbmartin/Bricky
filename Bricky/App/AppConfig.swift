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
        /// Offer a ghost pose fitted to the depth under the reticle (M2.7).
        /// Off until device rows show wrong proposals stay under 5%.
        static let suggestedPlacementEnabled = "developer.suggestedPlacementEnabled"
        /// Spoken steps and voice commands in the AR guide (M2.8,
        /// ADR 0016). Off until the Phase 1 hands-free checks pass.
        static let handsFreeEnabled = "developer.handsFreeEnabled"
        /// The RGB term's say over step verdicts (M3.2, ADR 0008 amendment,
        /// Proposed): a `ColourTermMode` raw value. Off by default; the app
        /// offers Off, Shadow and Block only until real windows support more.
        static let colourTermMode = "developer.colourTermMode"
        /// Repair sentences reworded by the on-device language model
        /// (M3.3, ADR 0017), validated against the plan, with the template
        /// as fallback. Off until device pairs win a blinded preference test.
        static let languageModelWordingEnabled = "developer.languageModelWordingEnabled"
        /// The on-device language model judges each AR photo check in
        /// shadow beside the VLM (M3.4, ADR 0018): recorded with evidence
        /// capture on, never shown. Device rows decide ADR 0018.
        static let fmShadowCheckEnabled = "developer.fmShadowCheckEnabled"
        /// Model titles in Spotlight (ADR 0016). Off by default; turning it
        /// off removes every entry.
        static let spotlightModelsEnabled = "privacy.spotlightModelsEnabled"
    }
}
