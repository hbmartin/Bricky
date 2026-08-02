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
                    await partPack.checkInstalled()
                    await recoveryModel.check()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        Task {
                            // ✅ VERIFIED: cancel and await MLX generation before
                            // suspension; outstanding Metal callbacks can abort.
                            await recoveryModel.cancelAndAwait()
                        }
                    }
                }
        }
        .modelContainer(modelContainer)
    }
}
