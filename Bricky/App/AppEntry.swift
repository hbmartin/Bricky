import SwiftData
import SwiftUI

@main
struct AppEntry: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = InstructionLibraryController()
    @StateObject private var partPack = LDrawPartPackManager()
    @StateObject private var recoveryModel = RecoveryModelManager()
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try InstructionPersistence.container()
        } catch {
            fatalError("Bricky could not open its new instruction library: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(partPack)
                .environmentObject(recoveryModel)
                .task {
                    sweepOrphanedRecoveryWorkFiles()
                    await partPack.checkInstalled()
                    await recoveryModel.check()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Only suspend on .background: .inactive also fires for
                    // Control Center and the app switcher, where cancelling a
                    // 3 GB download or warm inference is far too aggressive.
                    if phase == .background {
                        Task {
                            // ✅ VERIFIED: cancel and await MLX generation before
                            // suspension; outstanding Metal callbacks can abort.
                            // cancelAndAwait also drains view-started inference
                            // registered via trackInference.
                            await recoveryModel.cancelAndAwait()
                        }
                    }
                }
        }
        .modelContainer(modelContainer)
    }

    /// Removes recovery work files orphaned by a crash or force-quit. Runs
    /// once at startup, before any capture or inference flow can begin.
    /// Retained milestone images registered in SwiftData keep their original
    /// `RecoveryCaptures/` paths, so referenced files are preserved.
    private func sweepOrphanedRecoveryWorkFiles() {
        guard let root = try? InstructionModelImporter.applicationSupportRoot() else { return }
        let records = (try? modelContainer.mainContext.fetch(FetchDescriptor<StepMilestoneRecord>())) ?? []
        let referenced = Set(records.map(\.imageRelativePath))
        let fileManager = FileManager.default
        for folder in ["RecoveryCaptures", "InferenceBoards"] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for file in files where !referenced.contains("\(folder)/\(file.lastPathComponent)") {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
