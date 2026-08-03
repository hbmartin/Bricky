import SwiftData
import SwiftUI

struct ContentView: View {
    @Query(sort: \StoredInstructionModel.lastOpenedAt, order: .reverse) private var models: [StoredInstructionModel]
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
