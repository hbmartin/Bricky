import SwiftUI

struct ContentView: View {
    @State private var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: UserDefaultsKey.hasCompletedOnboarding)
    @State private var navigationPath = NavigationPath()

    /// Use device idiom instead of horizontalSizeClass — on Plus/Pro Max iPhones,
    /// landscape flips horizontalSizeClass to .regular which would otherwise tear
    /// down the NavigationStack and dump the user back on Home.
    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        if hasCompletedOnboarding {
            if isPad {
                iPadLayout
            } else {
                MainTabView(homePath: $navigationPath)
            }
        } else {
            OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
        }
    }

    // MARK: - iPad Layout

    private var iPadLayout: some View {
        AdaptiveSplitView()
    }
}

// MARK: - iPhone Tab Bar

/// Bottom tab strip for iPhone with four primary destinations:
/// Home, Sets, Feed, and Games. Each tab owns its own `NavigationStack`
/// so navigation state is preserved independently per tab.
struct MainTabView: View {
    /// Navigation path for the Home tab. Bound from `ContentView` so a
    /// finishing scan flow can pop the Home stack back to its root.
    @Binding var homePath: NavigationPath
    @State private var selectedTab: Tab = .home

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case home, sets, feed, games

        var id: String { rawValue }

        /// User-facing tab label (Title Case).
        var title: String {
            switch self {
            case .home: return "Home"
            case .sets: return "Sets"
            case .feed: return "Feed"
            case .games: return "Games"
            }
        }

        /// SF Symbol shown in the tab bar.
        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .sets: return "shippingbox.fill"
            case .feed: return "rectangle.stack.fill"
            case .games: return "puzzlepiece.fill"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                HomeView()
            }
            .tabItem { Label(Tab.home.title, systemImage: Tab.home.icon) }
            .tag(Tab.home)

            NavigationStack {
                SetCollectionView()
            }
            .tabItem { Label(Tab.sets.title, systemImage: Tab.sets.icon) }
            .tag(Tab.sets)

            NavigationStack {
                CommunityFeedView()
            }
            .tabItem { Label(Tab.feed.title, systemImage: Tab.feed.icon) }
            .tag(Tab.feed)

            NavigationStack {
                PuzzleView()
            }
            .tabItem { Label(Tab.games.title, systemImage: Tab.games.icon) }
            .tag(Tab.games)
        }
        .onReceive(NotificationCenter.default.publisher(for: .scanFlowShouldPopToRoot)) { _ in
            // When a scan flow ends (confirm, cancel, or close), return to the
            // Home tab and pop its navigation stack back to the root. Without
            // this the user is left on PreScanAnalysisView or the scan view
            // itself after finishing identification.
            selectedTab = .home
            if !homePath.isEmpty {
                homePath = NavigationPath()
            }
        }
    }
}


// MARK: - iPad Adaptive Split View

/// Sidebar-based navigation for iPad with split view layout
struct AdaptiveSplitView: View {
    @State private var selectedTab: SidebarTab? = .home
    @StateObject private var cameraViewModel = CameraViewModel()

    enum SidebarTab: String, CaseIterable, Identifiable {
        case home = "Home"
        case scan = "Scan"
        case catalog = "Catalog"
        case builds = "Builds"
        case community = "Community"
        case games = "Games"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .scan: return "camera.viewfinder"
            case .catalog: return "tray.full.fill"
            case .builds: return "hammer.fill"
            case .community: return "person.3.fill"
            case .games: return "puzzlepiece.fill"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationTitle("\(AppConfig.appName)")
            .listStyle(.sidebar)
        } detail: {
            NavigationStack {
                switch selectedTab {
                case .home, .none:
                    HomeView()
                case .scan:
                    CameraScanView()
                case .catalog:
                    if !cameraViewModel.scanSession.pieces.isEmpty {
                        PieceCatalogView(pieces: cameraViewModel.scanSession.pieces)
                    } else {
                        ContentUnavailableView(
                            "No Pieces Yet",
                            systemImage: "tray",
                            description: Text("Scan some LEGO bricks to see your catalog")
                        )
                    }
                case .builds:
                    if !cameraViewModel.scanSession.pieces.isEmpty {
                        BuildSuggestionsView(pieces: cameraViewModel.scanSession.pieces)
                    } else {
                        ContentUnavailableView(
                            "No Pieces Yet",
                            systemImage: "hammer",
                            description: Text("Scan some LEGO bricks to see build suggestions")
                        )
                    }
                case .community:
                    CommunityFeedView()
                case .games:
                    PuzzleView()
                case .settings:
                    SettingsView()
                }
            }
        }
    }
}
