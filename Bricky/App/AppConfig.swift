import Foundation

enum AppConfig {
    static let appName = "Bricky"
    static let bundleID = "com.bricky.app"
    static let queuePrefix = "com.bricky"
    static let applicationSupportNamespace = InstructionModelImporter.namespace
    /// The development-time semantic oracle version recorded in benchmark rows.
    static let pyldraw3Version = "1.5.0"

    /// UserDefaults keys for the developer evidence controls (ADR 0007).
    enum Defaults {
        static let evidenceCaptureEnabled = "developer.evidenceCaptureEnabled"
        static let corpusCollectionEnabled = "developer.corpusCollectionEnabled"
    }
}
