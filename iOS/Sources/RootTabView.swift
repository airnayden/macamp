// RootTabView — the adaptive top-level shell.
//
// On iPhone (compact width) the five destinations live in a `TabView` tab bar; on
// iPad (regular width) they become a `NavigationSplitView` sidebar + detail. Both
// present the same screens over the shared ``AppEnvironment``. The split layout's
// sidebar is branded with `Text(verbatim: "MacAMP")` (never localized).
import DesignSystem
import SwiftUI

/// The five top-level destinations of the iOS shell.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case library, playlists, nowPlaying, search, settings

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .library: MacAMPStrings.tabLibrary
        case .playlists: MacAMPStrings.tabPlaylists
        case .nowPlaying: MacAMPStrings.tabNowPlaying
        case .search: MacAMPStrings.tabSearch
        case .settings: MacAMPStrings.tabSettings
        }
    }

    var systemImage: String {
        switch self {
        case .library: "music.note.house"
        case .playlists: "music.note.list"
        case .nowPlaying: "play.circle"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

/// Adaptive root: a tab bar on iPhone, a sidebar split on iPad.
struct RootTabView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: AppTab = .library

    var body: some View {
        if sizeClass == .regular {
            splitLayout
        } else {
            tabLayout
        }
    }
}

// MARK: - Layouts

private extension RootTabView {
    var tabLayout: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                screen(for: tab)
                    .tabItem {
                        Label { Text(tab.label) } icon: { Image(systemName: tab.systemImage) }
                    }
                    .tag(tab)
            }
        }
    }

    var splitLayout: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(AppTab.allCases) { tab in
                    Label { Text(tab.label) } icon: { Image(systemName: tab.systemImage) }
                        .tag(tab)
                }
            }
            .navigationTitle(Text(verbatim: "MacAMP"))
            .navigationBarTitleDisplayMode(.large)
        } detail: {
            screen(for: selection)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Single-selection binding for the sidebar (falls back to the current tab).
    var sidebarSelection: Binding<AppTab?> {
        Binding(get: { selection }, set: { selection = $0 ?? selection })
    }

    @ViewBuilder
    func screen(for tab: AppTab) -> some View {
        switch tab {
        case .library: LibraryScreen()
        case .playlists: PlaylistsScreen()
        case .nowPlaying: NowPlayingScreen()
        case .search: SearchScreen()
        case .settings: SettingsScreen()
        }
    }
}

#Preview("iPhone") {
    RootTabView()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
}
