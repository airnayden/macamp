// AppEnvironment+MCP — composing the loopback MCP server into the shell.
//
// Two things live here and nowhere else:
//
//   1. The `.external`-tier toolbox, over the SAME `ProposalStore` the Assistant
//      pane reads. That is what makes `propose_playlist` from an outside agent
//      appear in the RUNNING app as an ordinary reviewable proposal, rather than
//      writing anything.
//   2. The observation that keeps the listener in step with the four settings that
//      govern it, in the shape `observeIntelligenceToggle` already established:
//      re-armed on every change, main-actor hop before re-reading because
//      `onChange` fires BEFORE the write lands.
//
// ── WHY THIS IS NOT INSIDE `makeAI` ──────────────────────────────────────────
//
// The AI graph is REPLACED on a master-toggle flip, a provider change, a model
// change and a profile switch. A listener rebuilt on each of those would drop an
// external client's session four ways for reasons that have nothing to do with it
// — so the server is owned by ``AppEnvironment`` and reaches the graph through a
// closure. The toolbox it finds there is always the current profile's.
import Foundation
import Observation
import Persistence
import Services
import ViewModels

extension AppEnvironment {
    /// The ten-tool library registry an external client sees, scoped to one profile.
    ///
    /// Its own `LibraryChatProposalFiler` rather than the chat's: the two share the
    /// store (which is the point) but not the DRAIN, so an MCP-filed proposal is
    /// never mistaken for the output of a chat turn nobody had.
    static func makeExternalToolbox(
        database: AppDatabase,
        profileId: Int64,
        proposals: ProposalStore,
        playback: (any ToolboxPlaybackControlling)? = nil
    ) -> LibraryToolbox {
        makeLibraryToolbox(
            database: database,
            profileId: profileId,
            proposals: LibraryChatProposalFiler(store: proposals),
            playback: playback
        )
    }

    /// Both registries an external client might see, over ONE proposal filer.
    ///
    /// Two toolboxes rather than one mutable toolbox because a `LibraryToolbox`
    /// builds its registry at `init` — which is what makes the grant unforgeable —
    /// and because the choice has to be made per CALL, not per graph build: the
    /// transport is stateless, so a client that flips the switch mid-session must
    /// see the new list on its very next `tools/list` without reconnecting. They
    /// share one ``LibraryChatProposalFiler`` so a proposal filed through either
    /// lands in the same review queue.
    static func makeExternalToolboxes(
        database: AppDatabase,
        profileId: Int64,
        proposals: ProposalStore,
        playback: any ToolboxPlaybackControlling
    ) -> (reading: LibraryToolbox, controlling: LibraryToolbox) {
        let filer = LibraryChatProposalFiler(store: proposals)
        let context = LibraryToolboxContext(
            tracks: TrackRepository(database),
            playlists: PlaylistRepository(database),
            digests: ListeningDigestBuilder(database),
            reader: ToolboxLibraryReader(database),
            proposals: filer,
            profileId: profileId
        )
        var controlling = context
        controlling.playback = playback
        return (LibraryToolbox(context: context), LibraryToolbox(context: controlling))
    }

    /// The registry an external client sees RIGHT NOW, control grant included.
    ///
    /// Read per `tools/list` and per `tools/call` rather than captured, because the
    /// transport is stateless: there is no session against which a capability set
    /// could have been negotiated, so each call re-reads the grant and the published
    /// list is always the current one. ``AppEnvironment/externalControlGranted`` is
    /// a plain box rather than a settings read because ``externalAccess``'s toolbox
    /// closure is `@Sendable` and captures no settings object; it is kept in step by
    /// ``applyExternalAccess(settings:)``.
    var currentExternalToolbox: LibraryToolbox? {
        guard let stack = intelligence else { return nil }
        return externalControlGranted ? stack.externalControlToolbox : stack.externalToolbox
    }

    /// Starts or stops the loopback server to match settings, and keeps doing so.
    func connectExternalAccess(settings: AppSettings) {
        applyExternalAccess(settings: settings)
        observeExternalAccess(settings: settings)
    }

    private func applyExternalAccess(settings: AppSettings) {
        // Set BEFORE `apply`, so a request served on the way back up from a restart
        // cannot read a stale grant.
        externalControlGranted = settings.externalAccessControlEnabled
        externalAccess.apply(settings: settings)
    }

    private func observeExternalAccess(settings: AppSettings) {
        withObservationTracking {
            // All five are graph SHAPE for the listener: the master switch (a
            // proposal has nowhere to be reviewed without it), the listener's own
            // switch, the disclosure, the port to bind, and the control grant.
            _ = settings.intelligenceEnabled
            _ = settings.externalAccessEnabled
            _ = settings.externalAccessConsented
            _ = settings.externalAccessPort
            _ = settings.externalAccessControlEnabled
        } onChange: { [weak self, weak settings] in
            Task { @MainActor in
                guard let self, let settings else { return }
                self.applyExternalAccess(settings: settings)
                self.observeExternalAccess(settings: settings)
            }
        }
    }
}
