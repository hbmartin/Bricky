import Foundation

/// The top-level areas under the `BrickyInstructionsV1` Application Support
/// root, and which of them device backups include.
///
/// Only what the user made is backed up: imported models, step history, the
/// retained capture images history records point at, and the SwiftData
/// store at the root. Everything that can be re-downloaded or is developer
/// scratch is excluded — the ~3.1 GB recovery model above all, which used to
/// land in every iCloud backup because the root was explicitly marked as
/// included on every access.
enum StorageLayout {
    enum Area: String, CaseIterable, Sendable {
        case models = "Models"
        case history = "History"
        /// Recovery photos. Milestone records keep pointing here after a
        /// capture is retained (`RecoveryImageStore.registerExistingCapture`),
        /// so excluding it would restore records whose images are gone.
        case recoveryCaptures = "RecoveryCaptures"
        case staging = "Staging"
        case inferenceBoards = "InferenceBoards"
        case recoveryModels = "RecoveryModels"
        case partPacks = "PartPacks"
        case evidence = "Evidence"

        var isBackedUp: Bool {
            switch self {
            case .models, .history, .recoveryCaptures: true
            case .staging, .inferenceBoards, .recoveryModels, .partPacks, .evidence: false
            }
        }
    }

    /// The area's directory under `root`, created if needed with its backup
    /// policy applied. Setting the flag on the directory covers everything
    /// inside it, and the app never deletes an area directory itself — only
    /// its contents — so the flag persists.
    static func directory(_ area: Area, root: URL, fileManager: FileManager = .default) throws -> URL {
        var url = root.appendingPathComponent(area.rawValue, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = !area.isBackedUp
        try url.setResourceValues(values)
        return url
    }

    /// Applies the policy to every area. Idempotent; runs at launch so data
    /// written by earlier builds is corrected without waiting for a write.
    static func applyBackupPolicy(root: URL, fileManager: FileManager = .default) throws {
        for area in Area.allCases {
            _ = try directory(area, root: root, fileManager: fileManager)
        }
    }
}
