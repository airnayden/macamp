// NavigationModel — the macOS shell's single home for navigation + UI-chrome state.
//
// Today the main window scatters its navigation across ad-hoc `@State`
// (`selection`, `showRightPanel`, `showNowPlayingExpanded`, `sidebarVisibility`), a
// `.id(destination)` remount trick, and a two-hop `NotificationCenter` relay for the
// artist drill-down. This type gives that state ONE observable owner so views,
// previews and (eventual) tests can read and drive navigation independently of the
// data graph (`AppEnvironment`) and the preference store (`AppSettings`).
//
// SCOPE — navigation + UI chrome ONLY. This model NEVER loads data: no repository
// reads, no view-model calls, no I/O beyond the sidebar-selection persistence it
// folds in. WHICH library window a destination shows, and HOW it is fetched, stays
// with the browsers / view models. Keeping data loading out is precisely what lets a
// view bind to navigation without dragging the whole object graph along.
//
// PERSISTENCE — the sidebar selection is the one piece of navigation that survives
// relaunch. The model owns a ``SidebarSelectionStore`` (the existing
// `UserDefaults`-backed wrapper in `StateRestoration.swift`) and drives it itself:
// `init(profileId:)` restores that profile's `SidebarDestination` via
// `store.load()`, and a `didSet`
// on `sidebar` writes each change back via `store.save(_:)`. Assignments in `init`
// do not fire `didSet`, so restoration never redundantly writes straight back (the
// same idiom `AppSettings` uses to hydrate). Every other property is transient
// session chrome and is intentionally NOT persisted.
//
// The type is `@MainActor @Observable` and injected once at the app root under its
// OWN environment key (`@Environment(NavigationModel.self)`), a peer to
// `AppEnvironment` and `AppSettings`.
//
// This is app-shell code; the AppKit/UIKit ban applies only to PlayerCore, so
// importing SwiftUI (for `NavigationSplitViewVisibility`) here is fine.
import Observation
import Persistence
import SwiftUI
import ViewModels

/// The tabs of the right (now-playing) panel. Declared here rather than in
/// `RightPanelView.swift` so ``NavigationModel`` — which owns the selection —
/// does not depend on a view file.
enum RightPanelTab: String, CaseIterable, Identifiable {
    case lyrics, tags, info, stats

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .lyrics: MacAMPStrings.panelLyrics
        case .tags: TagsPanelStrings.title
        case .info: InfoPanelStrings.title
        case .stats: StatsPanelStrings.title
        }
    }
}

/// The collapsible sidebar sections. Each `rawValue` IS the persisted dictionary
/// key, so renaming a case silently resets that section to expanded.
public enum SidebarSectionID: String, CaseIterable, Sendable {
    case library, playlists, karaoke, intelligence, folders
}

/// The observable owner of the main window's navigation + UI-chrome state.
///
/// Navigation state only — see the file header for the no-data-loading contract and
/// the sidebar-selection persistence this model folds in.
@MainActor
@Observable
public final class NavigationModel {
    /// The selected sidebar destination. Persisted on every change and restored at
    /// launch — one of the two pieces of navigation that survive relaunch.
    public var sidebar: SidebarDestination {
        didSet {
            if !isApplyingStoredState {
                store.save(sidebar)
            }
        }
    }

    /// Which sidebar sections are expanded, keyed by ``SidebarSectionID/rawValue``.
    /// A missing key reads as expanded, so a section introduced by a later build
    /// opens rather than hiding itself behind a chevron nobody knew to click.
    public var sidebarSectionExpanded: [String: Bool] {
        didSet {
            if !isApplyingStoredState {
                store.saveSectionExpansion(sidebarSectionExpanded)
            }
        }
    }

    /// The artist whose detail is being drilled into, or `nil` when none. Supersedes
    /// the two-hop `NotificationCenter` artist relay (wired up in a later task);
    /// transient, never persisted.
    public var artistDetail: Int64?

    /// Whether the right (now-playing / queue) panel is shown. Transient chrome.
    public var showRightPanel: Bool

    /// Which tab the right panel shows. Transient chrome; lifted off
    /// `RightPanelView`'s local state so any surface can open the panel on a tab.
    var rightPanelTab: RightPanelTab

    /// Whether the expanded now-playing overlay is presented. Transient chrome.
    public var showNowPlayingOverlay: Bool

    /// Whether the Netflix-style profile-switch overlay is presented. Transient
    /// chrome — never persisted, mirroring ``showNowPlayingOverlay``.
    public var showProfileOverlay: Bool

    /// Whether the equalizer overlay is presented. Transient chrome.
    public var showEQOverlay: Bool

    /// The AI proposal awaiting review, or `nil`. Transient chrome.
    ///
    /// Lives HERE rather than on the view that raised it because the contextual
    /// actions fire from three different places — the track context menu, the
    /// library toolbar and the playlist context menu — and a sheet can only be
    /// presented by a view that is still on screen when the menu closes. One
    /// window-level slot means one `.sheet` in ``MainWindowView`` and one review
    /// surface, instead of a copy per menu.
    public var pendingProposal: AIProposal?

    /// Whether the Downloads paste-links sheet is presented. Transient chrome.
    ///
    /// Window-level rather than local to the pane because TWO surfaces raise it — the
    /// Downloads toolbar `+` and the File-menu item, which fires from the app scene
    /// where the pane may not be on screen at all. Same reasoning as
    /// ``pendingProposal``.
    public var showDownloadsPasteSheet: Bool

    /// The split view's column visibility (sidebar shown / hidden). Transient chrome.
    public var sidebarVisibility: NavigationSplitViewVisibility

    /// Persists + restores `sidebar` and `sidebarSectionExpanded` only. Owned and
    /// driven internally; the model is the sole caller of its load/save pairs.
    @ObservationIgnored private var store: SidebarSelectionStore
    @ObservationIgnored private var isApplyingStoredState = false

    /// Restores the last sidebar selection (falling back to `.fixed(.allTracks)`) and
    /// section expansion, then defaults all transient chrome. `init` assignments do
    /// not fire `didSet`, so restoration never writes straight back.
    init(store: SidebarSelectionStore) {
        self.store = store
        sidebar = store.load() ?? .fixed(.allTracks)
        sidebarSectionExpanded = store.loadSectionExpansion()
        artistDetail = nil
        showRightPanel = true
        rightPanelTab = .lyrics
        showNowPlayingOverlay = false
        showProfileOverlay = false
        showEQOverlay = false
        showDownloadsPasteSheet = false
        sidebarVisibility = .all
    }

    /// Builds a navigation session scoped to `profileId`. Launch restoration writes
    /// any source-derived destination before this initializer reads the store.
    public convenience init(profileId: Int64 = ProfileRecord.guestID) {
        self.init(store: SidebarSelectionStore(profileId: profileId))
    }
}

// MARK: - Folder selection ownership

/// Decides whether a restored `.folder(rootId:)` belongs to the incoming profile.
///
/// A ROOT is owned when its stable id is among the incoming profile's roots. A
/// SUBFOLDER has no such id to match: at switch time only roots are materialized and
/// the live tree is still scoped to the OUTGOING profile, so its path comes from the
/// incoming profile's own persisted id→path pair and is then prefix-matched against
/// the owned roots. Without that second step every switch drops a subfolder selection
/// to All Tracks.
struct FolderSelectionOwnership {
    let rootIds: Set<Int64>
    let rootPaths: [String]
    let pathForId: @Sendable (Int64) -> String?

    /// Resolves nothing, so ``owns(rootId:)`` is false and ``disowns(rootId:)`` is
    /// false — the permissive shape a caller with no folder context passes.
    static let none = FolderSelectionOwnership(rootIds: [], rootPaths: [], pathForId: { _ in nil })

    func owns(rootId: Int64) -> Bool {
        if rootIds.contains(rootId) { return true }
        guard let path = pathForId(rootId) else { return false }
        return rootPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Positive evidence of foreignness: the path resolves and sits under none of this
    /// profile's roots. An UNRESOLVABLE id is not disowned — the playback-restore path
    /// writes `.folder` ids from `LibraryRootRecord.id`, which this set never contains.
    func disowns(rootId: Int64) -> Bool {
        pathForId(rootId) != nil && !owns(rootId: rootId)
    }
}

// MARK: - Profile switch

extension NavigationModel {
    /// Strict: a restored `.folder` must be POSITIVELY owned by the incoming profile.
    func resetForProfileSwitch(profileId: Int64, folderOwnership: FolderSelectionOwnership) {
        artistDetail = nil
        store = store.scoped(to: profileId)
        applyStoredSectionExpansion()
        let restored = store.load() ?? .fixed(.allTracks)
        switch restored {
        case let .folder(rootId):
            applyStoredSidebar(folderOwnership.owns(rootId: rootId) ? restored : .fixed(.allTracks))
        case .fixed, .playlist:
            applyStoredSidebar(restored)
        }
    }

    /// Permissive: rejects a `.folder` only on positive evidence that it belongs to
    /// another profile. This runs off a playback-state restore, whose `.folder` ids
    /// come from `LibraryRootRecord.id` rather than the tree's stable path hash, so a
    /// strict check here would discard every restored folder source.
    func restoreSidebarForProfileSwitch(
        profileId: Int64,
        folderOwnership: FolderSelectionOwnership = .none
    ) {
        store = store.scoped(to: profileId)
        applyStoredSectionExpansion()
        guard let restored = store.load() else { return }
        if case let .folder(rootId) = restored, folderOwnership.disowns(rootId: rootId) { return }
        applyStoredSidebar(restored)
    }

    private func applyStoredSidebar(_ destination: SidebarDestination) {
        guard destination != sidebar else { return }
        isApplyingStoredState = true
        sidebar = destination
        isApplyingStoredState = false
    }

    private func applyStoredSectionExpansion() {
        let restored = store.loadSectionExpansion()
        guard restored != sidebarSectionExpanded else { return }
        isApplyingStoredState = true
        sidebarSectionExpanded = restored
        isApplyingStoredState = false
    }
}

// MARK: - Section expansion

extension NavigationModel {
    func isSectionExpanded(_ section: SidebarSectionID) -> Bool {
        sidebarSectionExpanded[section.rawValue] ?? true
    }
}

// MARK: - Karaoke availability

extension NavigationModel {
    /// Drops a live ``LibrarySection/karaoke`` selection back to All Tracks when
    /// karaoke becomes unavailable (the user disables it, or the separator model
    /// is absent), so the selection never dangles on a now-hidden Karaoke section.
    /// A no-op for any other destination or while karaoke stays available.
    func reconcileKaraoke(available: Bool) {
        let resolved = sidebar.resolvedForKaraokeAvailability(available)
        if resolved != sidebar { sidebar = resolved }
    }
}

// MARK: - Assistant availability

extension NavigationModel {
    /// Drops a live or restored ``LibrarySection/assistant`` selection back to All
    /// Tracks when the Intelligence master toggle is off, so the selection never
    /// dangles on a now-hidden Assistant section. A no-op for any other destination
    /// or while the assistant stays available.
    ///
    /// Deliberately a second method rather than an extra argument on
    /// ``reconcileKaraoke(available:)``: the two toggles are independent and fire
    /// from independent triggers, so a merged call would make every caller supply
    /// an answer it may not have.
    func reconcileAssistant(available: Bool) {
        let resolved = sidebar.resolvedForAssistantAvailability(available)
        if resolved != sidebar { sidebar = resolved }
    }
}
