import Foundation

enum AppConfig {
    static let appName = "Bricky"
    static let bundleID = "com.bricky.app"
    static let queuePrefix = "com.bricky"
    static let keychainPrefix = queuePrefix
    static let applicationSupportNamespace = InstructionModelImporter.namespace
}
