import SwiftData
import SwiftUI

struct ContentView: View {
    @Query(sort: \StoredInstructionModel.lastOpenedAt, order: .reverse) private var models: [StoredInstructionModel]
    @Environment(\.modelContext) private var context
    @Environment(BuildSessionController.self) private var buildSession
    @EnvironmentObject private var library: InstructionLibraryController
    @State private var selection: Destination = .library

    enum Destination: Hashable {
        case library
        case recovery
        case guide
        case storage
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                .tag(Destination.library)

            NavigationStack {
                if let model = models.first {
                    RecoveryFlowView(model: model, onFinished: { selection = .guide })
                } else {
                    EmptyLibraryView(action: { selection = .library })
                }
            }
            .tabItem { Label("Recovery", systemImage: "camera.metering.matrix") }
            .tag(Destination.recovery)

            NavigationStack {
                if let model = models.first {
                    GuideView(model: model)
                } else {
                    EmptyLibraryView(action: { selection = .library })
                }
            }
            .tabItem { Label("Guide", systemImage: "square.stack.3d.up.fill") }
            .tag(Destination.guide)

            NavigationStack { StorageAndAttributionView() }
                .tabItem { Label("Storage", systemImage: "internaldrive.fill") }
                .tag(Destination.storage)
        }
        .onOpenURL { url in Task { await open(url) } }
    }

    /// "Open in Bricky": import the file (the importer takes the
    /// security-scoped access), then land on its guide. Failures land on the
    /// Library, whose alert shows the reason.
    private func open(_ url: URL) async {
        switch DocumentOpenRouter.route(url) {
        case .rejected(let reason):
            library.importError = reason
            selection = .library
        case .importFile(let file):
            let imported = await library.importSource(.file(file), into: context)
            if DocumentOpenRouter.isInboxCopy(file) {
                try? FileManager.default.removeItem(at: file)
            }
            guard let imported else {
                selection = .library
                return
            }
            do {
                try buildSession.open(imported, loader: library, context: context)
                selection = .guide
            } catch {
                library.importError = error.localizedDescription
                selection = .library
            }
        }
    }
}

private struct EmptyLibraryView: View {
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Instruction Model", systemImage: "square.and.arrow.down")
        } description: {
            Text("Import an authored MPD or stepped LDR first.")
        } actions: {
            Button("Open Library", action: action).buttonStyle(.borderedProminent)
        }
        .navigationTitle("Bricky")
    }
}
