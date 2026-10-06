import AppIntents
import SwiftData
import SwiftUI
import UIKit

@main
struct AppEntry: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = InstructionLibraryController()
    @StateObject private var partPack = LDrawPartPackManager()
    @StateObject private var recoveryModel = RecoveryModelManager()
    @State private var buildSession: BuildSessionController
    @State private var lifecycleTeardownTask: Task<Void, Never>?
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try InstructionPersistence.container()
        } catch {
            fatalError("Bricky could not open its new instruction library: \(error.localizedDescription)")
        }
        let session = BuildSessionController()
        _buildSession = State(initialValue: session)
        // Siri and Shortcuts act through the same session and library the
        // views use, so a spoken "next" and a tap cannot disagree (ADR 0016).
        let container = modelContainer
        AppDependencyManager.shared.add(dependency: session)
        AppDependencyManager.shared.add(dependency: container)
    }

    var body: some Scene {
        WindowGroup {
            let floor = DeviceFloor.current
            if floor == .supported {
                supportedRoot
            } else {
                UnsupportedDeviceView(verdict: floor)
            }
        }
        .modelContainer(modelContainer)
        // iOS relaunches the app, possibly in the background, to deliver the
        // model download's session events. The delegate only moves finished
        // files aside; hashing and publishing wait for the foreground.
        .backgroundTask(.urlSession(BackgroundModelTransfer.identifier)) {
            await BackgroundModelTransfer.shared.handleBackgroundEvents()
        }
    }

    /// The floor is the iPhone 17 Pro class for the whole app (ADR 0012):
    /// registration, verification, and occlusion all assume scene depth, and
    /// on-device inference assumes its memory, so no degraded experience is
    /// offered below it.
    private var supportedRoot: some View {
            ContentView()
                .environment(buildSession)
                .environmentObject(library)
                .environmentObject(partPack)
                .environmentObject(recoveryModel)
                .task {
                    // Before anything downloads: exclude re-downloadable and
                    // developer data from device backups (StorageLayout).
                    if let root = try? InstructionModelImporter.applicationSupportRoot() {
                        try? StorageLayout.applyBackupPolicy(root: root)
                    }
                    // Compile the expected-depth shader once, off the main
                    // thread, before the first AR verification needs it.
                    Task.detached(priority: .utility) {
                        _ = try? ExpectedDepthRenderer.shared()
                    }
                    // The sweep only touches capture/board folders, which are
                    // written strictly after model admission, so it can run
                    // concurrently without delaying the part-pack and model
                    // checks behind the milestone fetch.
                    // Spotlight holds models only while the user wants it
                    // to; this also clears entries left by a replaced model.
                    try? await InstructionModelSpotlight.sync(context: modelContainer.mainContext)
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
                        // tear down warm inference.
                        scheduleLifecycleTeardown(gracePeriod: .seconds(2))
                    case .background:
                        // The model download belongs to the background
                        // session and keeps going; only model work stops.
                        scheduleLifecycleTeardown()
                    default:
                        break
                    }
                }
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
            RecoveryWorkFileCleanup.sweepOrphanedWorkFiles(root: root, referencedCapturePaths: referenced)
        }.value
    }

    /// Serializes lifecycle cleanup and holds a UIKit background assertion so
    /// cancellation and MLX teardown can finish after the phase transition.
    /// The assertion is taken synchronously, before any suspension point, so
    /// iOS cannot suspend the process in the window before the teardown task
    /// first runs. Cancellation only aborts the grace period: past it, the
    /// drain ignores cancellation and runs to completion.
    private func scheduleLifecycleTeardown(gracePeriod: Duration? = nil) {
        let previous = lifecycleTeardownTask
        // A superseding teardown collapses a pending grace period instead of
        // waiting it out; a drain already past its grace sleep is unaffected.
        previous?.cancel()
        let assertion = LifecycleAssertion(name: "Bricky inference teardown")
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
            await recoveryModel.suspendInferenceAndAwait()
        }
    }
}

/// Shown instead of the app below the device floor. There is no degraded
/// mode to fall back to, so the screen explains the requirement instead.
private struct UnsupportedDeviceView: View {
    let verdict: DeviceFloor.Verdict

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }

    private var title: String {
        switch verdict {
        case .macNotSupported: "iPhone Required"
        case .noLiDAR: "LiDAR Required"
        case .supported, .unsupportedModel, .insufficientMemory: "iPhone 17 Pro Required"
        }
    }

    private var symbol: String {
        switch verdict {
        case .macNotSupported: "iphone"
        case .noLiDAR: "arkit"
        case .supported, .unsupportedModel, .insufficientMemory: "iphone.gen3"
        }
    }

    private var message: String {
        switch verdict {
        case .macNotSupported:
            "Bricky aligns and checks your build with an iPhone's LiDAR scanner, so it runs on iPhone 17 Pro and iPhone 17 Pro Max rather than on a Mac."
        case .noLiDAR:
            "Bricky aligns and checks your build using the LiDAR scanner, and requires iPhone 17 Pro or iPhone 17 Pro Max."
        case .supported, .unsupportedModel, .insufficientMemory:
            "Bricky needs the LiDAR scanner and memory of iPhone 17 Pro or iPhone 17 Pro Max, or a later Pro model. This device is not supported."
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
