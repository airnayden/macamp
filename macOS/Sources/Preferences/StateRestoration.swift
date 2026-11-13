// StateRestoration — apply startup defaults and persist the window frame.
//
// At launch this controller pushes the user's persisted EQ / ReplayGain /
// visualizer defaults into the live view models and starts FSEvents library
// watching (with one catch-up scan + availability reconcile so folders changed
// while the app was closed are caught). The window frame is persisted by
// AppKit's own `setFrameAutosaveName` (which writes to `UserDefaults`); the
// sidebar selection is persisted separately by `SidebarSelectionStore`. Launch
// restore may replace the active profile's value before `NavigationModel` reads
// it; after initialization the navigation model remains the sole writer.
//
// The controller is retained for the app's lifetime by the `.stateRestoration`
// modifier and its work is idempotent (only the first `restore()` runs).
//
// This is app-shell code; importing AppKit here is fine (the AppKit/UIKit ban
// applies only to PlayerCore).
import AppKit
import Foundation
import Persistence
import Services
import SwiftUI
import ViewModels

// MARK: - SidebarSelectionStore

/// Persists the sidebar ``SidebarDestination`` — and the sidebar's per-section
/// expansion — for restore-on-launch. Stores only the `Sendable` profile id +
/// suite name + key (resolving `UserDefaults` per call); the wrapper's `Codable`
/// tolerates a legacy bare `LibrarySection` raw value.
struct SidebarSelectionStore {
    static let defaultKey = "com.example.macamp.sidebarSelection"
    static let sectionExpansionKey = "com.example.macamp.sidebarSectionExpanded"

    private let profileId: Int64
    private let suiteName: String?
    private let key: String

    init(
        profileId: Int64,
        suiteName: String? = nil,
        key: String = SidebarSelectionStore.defaultKey
    ) {
        self.profileId = profileId
        self.suiteName = suiteName
        self.key = key
    }

    func load() -> SidebarDestination? {
        #if DEBUG
            seedFromLaunchEnvironmentIfNeeded()
        #endif
        guard let data = defaults.data(forKey: profileKey) else { return nil }
        return try? JSONDecoder().decode(SidebarDestination.self, from: data)
    }

    func save(_ destination: SidebarDestination) {
        guard let data = try? JSONEncoder().encode(destination) else { return }
        defaults.set(data, forKey: profileKey)
    }

    /// An absent or unreadable value decodes to an empty dictionary, which every
    /// section reads as expanded — so a first launch, a decode failure and a section
    /// added in a later build all degrade to the same fully open sidebar.
    ///
    /// A key naming a section that no longer exists is dropped here rather than
    /// carried: `saveSectionExpansion(_:)` persists the dictionary wholesale, so a
    /// retired id (Downloads, once it folded into Library) would otherwise be
    /// rewritten on every toggle for ever without anything ever reading it.
    func loadSectionExpansion() -> [String: Bool] {
        guard let data = defaults.data(forKey: sectionExpansionProfileKey) else { return [:] }
        let stored = (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
        return stored.filter { SidebarSectionID(rawValue: $0.key) != nil }
    }

    func saveSectionExpansion(_ expanded: [String: Bool]) {
        guard let data = try? JSONEncoder().encode(expanded) else { return }
        defaults.set(data, forKey: sectionExpansionProfileKey)
    }

    func scoped(to profileId: Int64) -> SidebarSelectionStore {
        SidebarSelectionStore(profileId: profileId, suiteName: suiteName, key: key)
    }

    private var profileKey: String {
        "\(key).profile.\(profileId)"
    }

    private var sectionExpansionProfileKey: String {
        "\(Self.sectionExpansionKey).profile.\(profileId)"
    }

    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        #if DEBUG
            if let uiTestSuite = Self.uiTestDefaults() {
                return uiTestSuite
            }
        #endif
        return .standard
    }

    #if DEBUG
        /// The throwaway suite `AppEnvironment.liveForUITesting()` already uses for
        /// every other preference, so a UI test's sidebar selection stops leaking into
        /// (and reading back out of) the real user's standard defaults. It is also the
        /// seam a UI test writes through to STAGE a persisted selection before launch —
        /// the payload is the wrapper's ordinary tagged JSON, pinned by
        /// `SidebarDestinationAssistantTests`.
        ///
        /// Requires BOTH launch variables, exactly like `liveForUITesting()`: without
        /// `UITEST_SEED_PATH` the app is a normal build and must keep using `.standard`.
        static func uiTestDefaults() -> UserDefaults? {
            let environment = ProcessInfo.processInfo.environment
            guard environment["UITEST_SEED_PATH"] != nil,
                  let runID = environment["UITEST_RUN_ID"]
            else { return nil }
            return UserDefaults(suiteName: "com.example.macamp.uitest.\(runID)")
        }

        /// Stages a persisted selection for XCUITest from `UITEST_SIDEBAR_SELECTION`
        /// (the wrapper's ordinary tagged JSON), so a test can exercise the
        /// restore-on-launch and dangle-guard paths.
        ///
        /// The launch ENVIRONMENT rather than a cross-process `UserDefaults` write,
        /// because the test runner writing into the app's suite is three failure modes
        /// deep: it needs the app to carry this DEBUG seam, it needs cfprefsd to publish
        /// a foreign domain before the app reads it, and — the one that actually bites —
        /// the runner then holds its own write in `UserDefaults`' in-process cache, so it
        /// can never observe the app's later rewrite (`synchronize()` does not invalidate
        /// that cache). XCTest hands `launchEnvironment` straight to the app process, so
        /// none of that applies.
        ///
        /// Seeds ONLY when the key is absent, which is what keeps the rest of the flow
        /// real: the app's own `save(_:)` governs from the first write onwards, so a
        /// dangle guard's rewrite is not clobbered on a relaunch and stays observable.
        private func seedFromLaunchEnvironmentIfNeeded() {
            guard let staged = ProcessInfo.processInfo.environment["UITEST_SIDEBAR_SELECTION"],
                  defaults.data(forKey: profileKey) == nil
            else { return }
            defaults.set(Data(staged.utf8), forKey: profileKey)
        }
    #endif
}

// MARK: - Playback source navigation

extension PlaybackSource {
    func sidebarDestination(among roots: [LibraryRootRecord]) -> SidebarDestination? {
        switch self {
        case let .librarySection(rawSection):
            return LibrarySection(rawValue: rawSection).map(SidebarDestination.fixed)
        case let .folder(path):
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            let root = roots.first { URL(fileURLWithPath: $0.path).standardizedFileURL.path == standardizedPath }
            return root?.id.map { .folder(rootId: $0) }
        case let .playlist(id):
            return .playlist(id: id)
        case .favourites:
            return .fixed(.favourites)
        case .karaokeReady:
            return .fixed(.karaoke)
        case .search, .albumDetail, .artistDetail, .stats:
            return nil
        }
    }
}

// MARK: - PlaybackStateRestorer

/// Restores the active profile's queue and optional source container. Coordinator
/// state remains the UI source of truth: karaoke-active snapshots publish only
/// after their asynchronous cache resolution completes.
@MainActor
struct PlaybackStateRestorer {
    private let repository: any ProfilePlaybackStateRepositoryProviding
    private let rootRepository: any LibraryRootRepositoryProviding
    private let coordinator: PlaybackCoordinator
    private let sidebarStore: SidebarSelectionStore
    private let sourceDidRestore: @MainActor (PlaybackSource) -> Void
    private let shouldApply: @MainActor () -> Bool

    init(
        repository: any ProfilePlaybackStateRepositoryProviding,
        rootRepository: any LibraryRootRepositoryProviding,
        coordinator: PlaybackCoordinator,
        sidebarStore: SidebarSelectionStore,
        sourceDidRestore: @escaping @MainActor (PlaybackSource) -> Void,
        shouldApply: @escaping @MainActor () -> Bool = { true }
    ) {
        self.repository = repository
        self.rootRepository = rootRepository
        self.coordinator = coordinator
        self.sidebarStore = sidebarStore
        self.sourceDidRestore = sourceDidRestore
        self.shouldApply = shouldApply
    }

    init(
        environment: AppEnvironment,
        profileId: Int64,
        shouldApply: @escaping @MainActor () -> Bool = { true }
    ) {
        self.init(
            repository: ProfilePlaybackStateRepository(environment.database),
            rootRepository: LibraryRootRepository(environment.database),
            coordinator: environment.coordinator,
            sidebarStore: SidebarSelectionStore(profileId: profileId),
            sourceDidRestore: { [weak environment] source in
                environment?.recordPlaybackSource(source)
            },
            shouldApply: shouldApply
        )
    }

    @discardableResult
    func restore(profileId: Int64) async -> Bool {
        guard let record = try? await repository.fetch(for: profileId) else { return false }
        guard let snapshot = try? JSONDecoder().decode(
            CoordinatorSnapshot.self,
            from: Data(record.snapshotJson.utf8)
        ) else { return false }

        let source = record.sourceJson.flatMap { sourceJson in
            try? JSONDecoder().decode(PlaybackSource.self, from: Data(sourceJson.utf8))
        }
        let roots: [LibraryRootRecord] = if let source {
            await rootsIfNeeded(for: source, profileId: profileId)
        } else {
            []
        }
        guard shouldApply() else { return false }

        coordinator.restore(from: snapshot)
        coordinator.setRestoredSource(source)
        if let source {
            if let destination = source.sidebarDestination(among: roots) {
                sidebarStore.save(destination)
            }
            sourceDidRestore(source)
        }
        return true
    }

    private func rootsIfNeeded(for source: PlaybackSource, profileId: Int64) async -> [LibraryRootRecord] {
        guard case .folder = source else { return [] }
        let rootRepository = rootRepository
        return await Task.detached {
            (try? rootRepository.rootsForProfile(profileId, limit: LibraryRootRepository.fetchLimit)) ?? []
        }.value
    }
}

// MARK: - StateRestorationController

/// Applies the user's startup defaults and starts library watching at launch.
@MainActor
final class StateRestorationController {
    let environment: AppEnvironment
    private let settings: AppSettings
    private var hasRestored = false
    /// Stored state for ``beginCatchUp()``, which ships in `StateRestoration+CatchUp.swift`
    /// — Swift forbids stored properties in an extension, so both flags live here.
    var hasBegunCatchUp = false
    var catchUpTask: Task<Void, Never>?

    init(environment: AppEnvironment, settings: AppSettings) {
        self.environment = environment
        self.settings = settings
    }
}

// MARK: - Restore

extension StateRestorationController {
    /// Applies the user's startup defaults and starts library watching.
    /// Idempotent — only the first call does the work.
    func restore() async {
        guard !hasRestored else { return }
        hasRestored = true
        // Startup changes the splash view's identity, which cancels its SwiftUI
        // `.task`. A detached MainActor task keeps restore independent of that lifetime.
        let restorationTask = Task.detached { [self] in
            await runRestoreSequence()
        }
        await restorationTask.value
    }

    /// The FAST phase only. Watcher start, catch-up scan, availability reconcile and
    /// the generated-playlist refresh are owned by ``beginCatchUp()`` instead, so the
    /// splash never waits on the filesystem.
    private func runRestoreSequence() async {
        applyStartupDefaults()
        await restorePlaybackState()
    }
}

// MARK: - Startup defaults

extension StateRestorationController {
    /// Pushes the persisted EQ / ReplayGain / visualizer defaults into the live
    /// view models at launch.
    func applyStartupDefaults() {
        environment.equalizer.loadPresets()
        environment.equalizer.applyPreset(named: settings.defaultEQPresetName)
        environment.equalizer.setReplayGainMode(settings.replayGainMode)
        environment.visualizer.setMode(settings.defaultVisualizerMode)
        applyProfilesStartupState()
    }

    /// Reconciles the profiles session with the persisted feature flag at launch.
    ///
    /// `ProfileService.init` has already restored the active profile from its own
    /// `activeProfileId`, so this only enforces the disabled contract: feature off
    /// ⇒ Guest is active. We deliberately never call `setEnabled(true)` here — its
    /// `restoreLastActiveProfile()` drops to Guest when `lastActiveProfileId` is
    /// unset (the common relaunch case), clobbering the profile `init` just
    /// restored. The `profilesEnabled` mirror is not read by any UI (the avatar
    /// button gates on `AppSettings.profilesEnabled`); it becomes authoritative the
    /// moment the user toggles the Profiles pane. The guard skips the redundant
    /// `setEnabled(false)` when Guest is already active, so `lastActiveProfileId`
    /// is never overwritten in the normal flow.
    func applyProfilesStartupState() {
        guard !settings.profilesEnabled,
              environment.profileService.activeProfile.id != ProfileRecord.guestID
        else { return }
        environment.profileService.setEnabled(false)
    }

    func restorePlaybackState() async {
        let profileId = environment.profileService.activeProfile.id ?? ProfileRecord.guestID
        let restorer = PlaybackStateRestorer(environment: environment, profileId: profileId)
        await restorer.restore(profileId: profileId)
    }

    /// The app-launch half of the auto-mix refresh seam (the other is a surface
    /// appearing). Runs AFTER the catch-up scan, so a mix is drawn from the library
    /// as it is now rather than as it was when the app last closed.
    ///
    /// Costs nothing twice over when it should: `intelligence` is `nil` while the
    /// master toggle is off, and `refreshIfStale` returns before touching the
    /// generator when every kind is inside its TTL.
    func refreshGeneratedPlaylistsIfStale() async {
        guard let generated = environment.intelligence?.generatedPlaylists else { return }
        let profileId = environment.profileService.activeProfile.id ?? ProfileRecord.guestID
        _ = try? await generated.refreshIfStale(profileId: profileId)
    }
}

// MARK: - Window frame autosave

/// Installs an AppKit frame-autosave name on the hosting window so its size and
/// position persist across launches (AppKit stores the frame in `UserDefaults`).
struct WindowFrameAutosaver: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context _: Context) -> NSView {
        let view = WindowAutosaveView()
        view.autosaveName = autosaveName
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

/// A zero-size helper view that names its window for frame autosave the moment it
/// attaches to a window.
private final class WindowAutosaveView: NSView {
    var autosaveName: NSWindow.FrameAutosaveName = ""

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !autosaveName.isEmpty else { return }
        window.setFrameAutosaveName(autosaveName)
    }
}

// MARK: - Wiring modifier

private struct StateRestorationModifier: ViewModifier {
    let controller: StateRestorationController

    func body(content: Content) -> some View {
        content
            .background(WindowFrameAutosaver(autosaveName: "MacAMPMainWindow"))
            .task {
                await controller.restore()
                controller.beginCatchUp()
            }
    }
}

extension View {
    /// Applies startup defaults, starts library watching, and installs
    /// window-frame autosave. Apply once to the main window content.
    func stateRestoration(controller: StateRestorationController) -> some View {
        modifier(StateRestorationModifier(controller: controller))
    }
}
