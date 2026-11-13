// LyricsBrowserView — the sidebar `.lyrics` detail: every track in the active
// profile's library whose lyrics are already cached, keyset-paginated through the
// shared `LyricsBrowserViewModel`.
//
// Selecting a row PREVIEWS its lyrics in the right panel (it does not start
// playback) — the panel is opened on its Lyrics tab through `NavigationModel`.
// Double-click (or the context-menu Play) plays the loaded window from the clicked
// row, exactly like the other list surfaces.
//
// There is deliberately NO search field here (an explicit out-of-scope item); the
// list is the whole cached-lyrics set, ordered like the library browser.
import DesignSystem
import Lyrics
import Persistence
import Services
import SwiftUI
import ViewModels

struct LyricsBrowserView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(NavigationModel.self) private var nav
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var selection = Set<Int64>()

    var body: some View {
        content
            .task(id: activeProfileId) { await load() }
            .onChange(of: selection) { _, ids in preview(ids) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lyrics.view")
    }
}

// MARK: - Content

private extension LyricsBrowserView {
    var model: LyricsBrowserViewModel {
        environment.lyricsBrowser
    }

    @ViewBuilder
    var content: some View {
        if !model.tracks.isEmpty {
            trackList
        } else if model.isLoading {
            StateView.loading()
                .synthwaveEmptyBackground()
        } else {
            StateView(
                systemImage: LibrarySection.lyrics.systemImage,
                title: MacAMPStrings.lyricsBrowserEmptyTitle,
                message: MacAMPStrings.lyricsBrowserEmptyMessage
            )
            .synthwaveEmptyBackground()
        }
    }

    var trackList: some View {
        List(selection: $selection) {
            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, row in
                trackRow(row, position: index + 1)
                    .tag(row.trackId)
                    .onAppear { paginate(at: index) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
        .accessibilityIdentifier("lyricsBrowser.list")
        .contextMenu(forSelectionType: Int64.self) { ids in
            Button { play(ids) } label: {
                Label { Text(MacAMPStrings.menuPlay) } icon: { Image(systemName: "play.fill") }
            }
        } primaryAction: { ids in
            play(ids)
        }
    }

    func trackRow(_ row: LyricsRowDTO, position: Int) -> some View {
        TrackListRow(
            number: position,
            title: row.title ?? row.filePath,
            artist: row.artist,
            duration: row.duration,
            isPlaying: row.trackId == environment.player.currentTrack?.trackID,
            availability: .present,
            isLyricsSynced: row.isSynced
        )
    }
}

// MARK: - Loading + actions

private extension LyricsBrowserView {
    var activeProfileId: Int64 {
        environment.profileService.activeProfile.id ?? ProfileRecord.guestID
    }

    func load() async {
        model.activeProfileId = activeProfileId
        try? await model.loadInitial()
    }

    func paginate(at index: Int) {
        guard index == model.tracks.count - 1 else { return }
        Task { try? await model.loadMore() }
    }

    /// Previews the clicked row's lyrics in the right panel, opening it on the
    /// Lyrics tab. Online lookup is the user's global preference — this view takes
    /// no network policy of its own.
    func preview(_ ids: Set<Int64>) {
        guard let id = ids.first, let row = model.tracks.first(where: { $0.trackId == id }) else { return }
        model.select(row.trackRef, options: settings.onlineLyricsEnabled ? .online : .offline)
        nav.rightPanelTab = .lyrics
        nav.showRightPanel = true
    }

    func play(_ ids: Set<Int64>) {
        let refs = model.tracks.map(\.trackRef)
        guard !refs.isEmpty else { return }
        let clickedId = ids.first
        let startIndex = refs.firstIndex { $0.trackID == clickedId } ?? 0
        environment.coordinator.setQueue(
            refs,
            startingAt: startIndex,
            source: .librarySection(LibrarySection.lyrics.rawValue)
        )
        environment.queue.refresh()
    }
}

#Preview {
    LyricsBrowserView()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .environment(NavigationModel())
        .designTokens(.standard)
        .frame(width: 720, height: 480)
}
