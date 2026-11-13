// PlaylistOrganizeMenu — the "Organize…" submenu, and the two playlist-level
// surfaces that carry it.
//
// EVERY ITEM ACTS ON THE WHOLE PLAYLIST. That is why this is no longer part of the
// per-ROW context menu inside ``PlaylistDetailView``: right-clicking one song and
// being offered "Remove Duplicates", "Split by Theme", "Reorder by Energy" and
// "Suggest a Name" — none of which look at the row that was clicked — reads as four
// actions on that song. It is attached instead to the surfaces that ARE the playlist:
// the sidebar row's context menu (beside Rename and Delete) and the playlist detail's
// own toolbar.
//
// EVERY ITEM PROPOSES; NONE WRITES. Each action reads the playlist, asks
// ``AssistantViewModel`` for an ``AIProposal``, and puts it in the window's review
// sheet. The repository is reached only by that sheet's Apply button, so a mis-click
// can never change a listener's playlist.
//
// The whole submenu is ABSENT — not disabled — while the `.organization` bundle is
// off, which is what a per-bundle switch is for. "Reorder by Energy" is the one item
// that can be present-but-disabled, because its precondition is a library the
// listener can fix (run the analysis pass) rather than a feature they turned off.
//
// The four actions and the pure aggregates behind them live in
// ``PlaylistOrganizeActions``, purely to keep each source under the SwiftLint
// file-length budget.
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

/// Where an organize action reads the playlist's COMPLETE ordered membership from.
///
/// Two cases because the two surfaces know different things. The detail view has
/// already paged the playlist into the shared ``PlaylistViewModel`` and can simply
/// finish draining it; the sidebar has not, and the shared view model is very likely
/// showing a DIFFERENT playlist — draining it there would both read the wrong rows
/// and disturb whatever the listener is browsing.
enum PlaylistOrganizeTrackSource {
    /// Finish draining the shared view model, which is already on this playlist.
    case loadedDetail
    /// Page this playlist straight out of the repository, off the main actor,
    /// touching no browsing state.
    case repositoryPages
}

struct PlaylistOrganizeMenu: View {
    let playlist: PlaylistRecord
    let trackSource: PlaylistOrganizeTrackSource

    @Environment(AppEnvironment.self) var environment
    @Environment(AppSettings.self) var settings
    @Environment(NavigationModel.self) var nav

    var body: some View {
        if showsOrganize {
            Menu {
                Button(action: organizeDeduplicate) {
                    Label { Text(AIActionStrings.organizeDeduplicate) } icon: {
                        Image(systemName: "square.on.square.dashed")
                    }
                }
                Button(action: organizeSplitByTheme) {
                    Label { Text(AIActionStrings.organizeSplit) } icon: {
                        Image(systemName: "square.split.2x1")
                    }
                }
                Button(action: organizeReorderByEnergy) {
                    Label { Text(AIActionStrings.organizeEnergy) } icon: {
                        Image(systemName: "waveform.path.ecg")
                    }
                }
                .disabled(!canReorderByEnergy)
                .help(canReorderByEnergy ? AIActionStrings.organizeEnergy : AIActionStrings.organizeEnergyUnavailable)
                Button(action: organizeSuggestName) {
                    Label { Text(AIActionStrings.organizeRename) } icon: { Image(systemName: "text.cursor") }
                }
            } label: {
                Label { Text(AIActionStrings.organize) } icon: { Image(systemName: "wand.and.stars") }
            }
            .accessibilityIdentifier("playlist.action.organize")
            .task { await environment.intelligence?.audioAnalysis.refreshAnalyzedFraction() }
        }
    }
}

// MARK: - Gates

extension PlaylistOrganizeMenu {
    /// Whether the surface offers "Organize…".
    ///
    /// `intelligence` is `nil` exactly while the Intelligence master toggle is off,
    /// so the two conditions together are the complete gate.
    var showsOrganize: Bool {
        environment.intelligence != nil && settings.isEnabled(.organization)
    }

    /// Whether enough of the library has been analysed for an energy arc to mean
    /// anything — ``MixRanking/energyArcCoverage``, the same threshold the mix
    /// pipeline applies to the selection it is handed.
    ///
    /// UNMEASURED COVERAGE ENABLES THE ITEM. `analyzedFraction` is filled by an
    /// asynchronous read, so until it lands it is `0` — and this body is a
    /// `.contextMenu` descendant, evaluated once when the menu is built and NOT
    /// rebuilt by the Observation change that follows. Reading the placeholder as
    /// a measurement is therefore not a brief flicker but a wrong answer that
    /// sticks: a fully analysed library shows "Reorder by Energy" permanently
    /// greyed out. That is the reported bug.
    ///
    /// The threshold itself is unchanged. What changes is which way the UNKNOWN
    /// case falls: offering an action that then explains precisely why it could
    /// not run (``AIProposalUnavailability/insufficientAnalysis(required:)``,
    /// measured on THIS playlist rather than on the library) is strictly more
    /// useful than a disabled control with no explanation at all.
    var canReorderByEnergy: Bool {
        guard let analysis = environment.intelligence?.audioAnalysis else { return false }
        guard analysis.hasMeasuredCoverage else { return true }
        return analysis.analyzedFraction >= MixRanking.energyArcCoverage
    }

    var organizeProfileId: Int64 {
        environment.profileService.activeProfile.id ?? ProfileRecord.guestID
    }
}

// MARK: - Draining

extension PlaylistOrganizeMenu {
    /// Rows read per repository round trip when draining from the sidebar.
    static var drainPageSize: Int {
        200
    }

    /// The playlist's COMPLETE ordered membership.
    ///
    /// The browse path stays keyset-windowed; an organize action is the same
    /// deliberate exception Edit Order already makes, because a proposal that
    /// rewrote membership from a partially loaded window would silently drop every
    /// track past the last loaded page.
    func drainedTracks() async -> [TrackRecord] {
        guard let playlistId = playlist.id else { return [] }
        switch trackSource {
        case .loadedDetail:
            while environment.playlists.hasMoreTracks {
                try? await environment.playlists.loadMoreTracks(in: playlistId)
            }
            return environment.playlists.tracks.map(\.track)
        case .repositoryPages:
            return await Self.pagedTracks(playlistId: playlistId, database: environment.database)
        }
    }

    /// Every membership row, paged off the main actor.
    ///
    /// FAIL-CLOSED, and that is the load-bearing part: a mid-drain read error returns
    /// an EMPTY list, never the pages that did arrive. `apply` rewrites membership
    /// from `proposedTrackIds` wholesale, so a truncated drain would produce a
    /// proposal that silently DELETES every track past the failure. An empty list
    /// makes the action report "nothing to suggest here yet" instead.
    static func pagedTracks(playlistId: Int64, database: AppDatabase) async -> [TrackRecord] {
        let pageSize = drainPageSize
        return await Task.detached(priority: .utility) { () -> [TrackRecord] in
            let repository = PlaylistRepository(database)
            var drained: [TrackRecord] = []
            var cursor: PageCursor<Int>?
            repeat {
                guard let page = try? repository.playlistTracksPage(
                    playlistId: playlistId,
                    after: cursor,
                    limit: pageSize
                ) else {
                    return []
                }
                drained.append(contentsOf: page.items.map(\.track))
                cursor = page.nextCursor
            } while cursor != nil
            return drained
        }.value
    }
}
