import SwiftData
import SwiftUI
import UIKit

@main
struct AppEntry: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = InstructionLibraryController()
    @StateObject private var partPack = LDrawPartPackManager()
    @StateObject private var recoveryModel = RecoveryModelManager()
    @State private var lifecycleTeardownTask: Task<Void, Never>?
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
                    // The sweep only touches capture/board folders, which are
                    // written strictly after model admission, so it can run
                    // concurrently without delaying the part-pack and model
                    // checks behind the milestone fetch.
                    async let sweep: Void = sweepOrphanedRecoveryWorkFiles()
                    await partPack.checkInstalled()
                    await recoveryModel.check()
                    await sweep
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Only the grace period is cancellable: a teardown
                        // that already started draining runs to completion,
                        // and the model re-warms through the normal UI path.
                        lifecycleTeardownTask?.cancel()
                    case .inactive:
                        // Begin draining Metal work before iOS suspends the
                        // process, but only after a grace period so Control
                        // Center, the app switcher, and system alerts do not
                        // tear down warm inference. Downloads are left
                        // running until a real background transition arrives.
                        scheduleLifecycleTeardown(cancelDownloads: false, gracePeriod: .seconds(2))
                    case .background:
                        scheduleLifecycleTeardown(cancelDownloads: true)
                    default:
                        break
                    }
                }
        }
        .modelContainer(modelContainer)
    }

    /// Removes recovery work files orphaned by a crash or force-quit. Runs
    /// once at startup, before any capture or inference flow can begin.
    /// Retained milestone images registered in SwiftData keep their original
    /// `RecoveryCaptures/` paths, so referenced files are preserved.
    private func sweepOrphanedRecoveryWorkFiles() async {
        guard let root = try? InstructionModelImporter.applicationSupportRoot() else { return }
        let referenced: Set<String>?
        do {
            var descriptor = FetchDescriptor<StepMilestoneRecord>()
            descriptor.propertiesToFetch = [\.imageRelativePath]
            let records = try modelContainer.mainContext.fetch(descriptor)
            referenced = Set(records.map(\.imageRelativePath))
        } catch {
            // A failed metadata fetch must never be interpreted as "nothing is
            // retained". Inference boards are always transient and can still
            // be swept, but recovery captures must be left untouched.
            referenced = nil
        }
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            for folder in ["RecoveryCaptures", "InferenceBoards"] {
                if folder == "RecoveryCaptures", referenced == nil { continue }
                let directory = root.appendingPathComponent(folder, isDirectory: true)
                guard let files = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ) else { continue }
                for file in files where referenced?.contains("\(folder)/\(file.lastPathComponent)") != true {
                    try? fileManager.removeItem(at: file)
                }
            }
        }.value
    }

    /// Serializes lifecycle cleanup and holds a UIKit background assertion so
    /// cancellation and MLX teardown can finish after the phase transition.
    /// The assertion is taken synchronously, before any suspension point, so
    /// iOS cannot suspend the process in the window before the teardown task
    /// first runs. Cancellation only aborts the grace period: past it, the
    /// drain ignores cancellation and runs to completion.
    private func scheduleLifecycleTeardown(cancelDownloads: Bool, gracePeriod: Duration? = nil) {
        let previous = lifecycleTeardownTask
        // A superseding teardown collapses a pending grace period instead of
        // waiting it out; a drain already past its grace sleep is unaffected.
        previous?.cancel()
        let assertion = LifecycleAssertion(
            name: cancelDownloads ? "Bricky background teardown" : "Bricky inference teardown"
        )
        lifecycleTeardownTask = Task {
            defer { assertion.end() }
            if let gracePeriod {
                do {
                    try await Task.sleep(for: gracePeriod)
                } catch {
                    // Back to `.active` (or superseded) during the grace
                    // period: nothing has been torn down yet.
                    return
                }
            }
            await previous?.value
            if cancelDownloads {
                await recoveryModel.cancelAndAwait()
            } else {
                await recoveryModel.suspendInferenceAndAwait()
            }
        }
    }
}

/// A UIKit background-task assertion whose expiration handler releases the
/// assertion itself, as UIKit requires. If teardown outlives the background
/// allowance the app races normal suspension instead of being terminated by
/// the watchdog (`0x8badf00d`).
@MainActor
private final class LifecycleAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // UIKit documents that expiration handlers run on the main thread.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
