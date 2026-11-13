import AppKit
import DesignSystem
import Persistence
import Services
import Sparkle
import SwiftUI
import ViewModels

@main
struct MacAMPApp: App {
    @NSApplicationDelegateAdaptor(MenuPruningDelegate.self) private var menuDelegate
    @State private var environment: AppEnvironment?
    @State private var settings: AppSettings
    /// The app's one Sparkle updater, built in `init()` rather than lazily: its
    /// channel-filtering delegate can only be supplied at construction (the
    /// controller exposes no setter), and it must exist before Sparkle's first
    /// automatic check fires.
    private let updaterController: SPUStandardUpdaterController
    /// Sparkle references its delegate weakly — this is the owning reference.
    private let updaterDelegate: SparkleUpdaterDelegate
    /// Observable façade the Settings pane and the App menu bind to.
    private let updater: UpdaterModel
    @State private var navigationModel: NavigationModel?
    @State private var stateRestorationController: StateRestorationController?
    @State private var playIntent = PlayIntent()
    @State private var isLoading = true
    @State private var splashPhase: SplashPhase = .loadingLibrary
    /// Guards one-time `AppEnvironment.live()` construction: `.task` can fire more than
    /// once across the splash→main transition, and a second composition root spins up
    /// duplicate engines and (under the UITest seam) an inconsistent karaoke stack.
    @State private var didBeginLaunch = false

    init() {
        UserDefaults.standard.set(500, forKey: "NSInitialToolTipDelay")
        MediaKeyMonitor.shared.start()
        // Re-supplies ⌘A/C/V/X/Z in text fields that the stripped Edit menu removed.
        TextEditingKeyMonitor.shared.start()
        // Seeded through `State(initialValue:)` so the updater's delegate reads the
        // very same settings object the Preferences window edits.
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        let delegate = SparkleUpdaterDelegate(settings: settings)
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        updaterDelegate = delegate
        updaterController = controller
        updater = UpdaterModel(controller: controller)
    }

    var body: some Scene {
        Window("MacAMP", id: "main") {
            Group {
                if isLoading || environment == nil {
                    SplashView(phase: splashPhase)
                        .designTokens(settings.designTokens)
                } else if let environment, let navigationModel, let stateRestorationController {
                    MainWindowView()
                        .environment(environment)
                        .environment(settings)
                        .environment(navigationModel)
                        .environment(playIntent)
                        .designTokens(settings.designTokens)
                        .preferredColorScheme(settings.appearance.colorScheme)
                        .stateRestoration(controller: stateRestorationController)
                }
            }
            .background(SplashWindowChrome(isSplash: isLoading))
            .task { await runSplash() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button { updater.checkForUpdates() } label: {
                    Text(PreferencesStrings.checkForUpdates)
                }
                .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button {
                    navigationModel?.sidebar = .fixed(.downloads)
                    navigationModel?.showDownloadsPasteSheet = true
                } label: {
                    Text(MacAMPStrings.downloadsPasteMenuItem)
                }
                .disabled(navigationModel == nil)
            }
            CommandGroup(replacing: .help) {}
            CommandGroup(replacing: .textEditing) {}
        }

        Settings {
            Group {
                if let environment, let navigationModel {
                    PreferencesView()
                        .environment(environment)
                        .environment(settings)
                        .environment(navigationModel)
                        .environment(updater)
                        .designTokens(settings.designTokens)
                        .preferredColorScheme(settings.appearance.colorScheme)
                }
            }
            // Both live OUTSIDE the `if let`: `environment` is nil for the ~1.5 s splash,
            // so anything nested inside never attaches when Settings is opened during launch.
            .frame(minWidth: PreferenceMetrics.windowMinWidth, minHeight: PreferenceMetrics.windowMinHeight)
            .background(SettingsWindowResizable())
        }
        .defaultSize(width: 860, height: 580)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)

        MenuBarExtra {
            if let environment {
                MenuBarView()
                    .environment(environment)
            }
        } label: {
            Image(systemName: "music.note")
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor
    private func runSplash() async {
        guard !didBeginLaunch else { return }
        didBeginLaunch = true
        sweepAbandonedDownloadStaging()
        try? await Task.sleep(for: .seconds(0.75))
        splashPhase = .startingEngine
        let env = AppEnvironment.live(settings: settings)
        let restorationController = StateRestorationController(environment: env, settings: settings)
        stateRestorationController = restorationController
        await restorationController.restore()
        let profileId = env.profileService.activeProfile.id ?? ProfileRecord.guestID
        navigationModel = NavigationModel(profileId: profileId)
        menuDelegate.terminationFlush = AppEnvironment.makeTerminationFlush(env)
        environment = env
        startInitialPlaylistLoad(env)
        try? await Task.sleep(for: .seconds(0.75))
        withAnimation(.easeInOut(duration: 0.5)) { isLoading = false }
        restorationController.beginCatchUp()
    }

    /// Deletes the `.part` / `.ytdl` / `.temp.*` files a previous run abandoned in the
    /// download staging directory.
    ///
    /// Detached and never awaited: it is directory I/O with no launch-critical result,
    /// and it is deliberately independent of `AppEnvironment` — the files outlive every
    /// object graph that made them. Safety comes from the sweeper's own age guard, not
    /// from when this runs: a crash-orphaned yt-dlp is reparented to launchd and may
    /// still be writing, so only files untouched for an hour are deleted.
    @MainActor
    private func sweepAbandonedDownloadStaging() {
        guard let staging = DownloadStagingLocation.defaultDirectory() else { return }
        Task.detached(priority: .utility) {
            _ = DownloadStagingSweeper.sweep(directory: staging)
        }
    }

    /// Loads playlists from an unstructured `Task` (not a view `.task`) so the
    /// splash→main transition cannot cancel it mid-flight — the launch bug that
    /// left the sidebar and "Add to playlist" menus empty until a re-navigation.
    @MainActor
    private func startInitialPlaylistLoad(_ env: AppEnvironment) {
        Task {
            for _ in 0 ..< 5 {
                do {
                    try await env.playlists.loadInitialPlaylists()
                    return
                } catch {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
    }
}

/// Removes the standard Edit and Help top-level menus the user does not want.
/// Identifies them by a member selector (title-independent / localization-proof):
/// Edit owns `undo:`, Help is `NSApp.helpMenu` or owns `showHelp:`. AppKit adds
/// the Help menu after launch, so we also prune once more on the next run loop.
/// It also owns the quit-time flush (see `MenuPruningDelegate+Termination.swift`):
/// `@NSApplicationDelegateAdaptor` allows exactly one adaptor per `App`, so this is
/// the only place an `NSApplicationDelegate` hook can live.
@MainActor
final class MenuPruningDelegate: NSObject, NSApplicationDelegate {
    /// Persists whatever quitting would otherwise lose. Assigned by the composition
    /// root once the environment exists; `nil` until then, which is why an early
    /// quit (during the splash) terminates immediately instead of hanging.
    var terminationFlush: (@MainActor () async -> Void)?
    /// How long the flush may take before the app quits anyway.
    var terminationFlushTimeout: Duration = .seconds(2)
    /// Replies owed to AppKit once the in-flight flush settles. A second terminate
    /// request joins the running flush rather than starting a second one.
    var pendingTerminationReplies: [(Bool) -> Void] = []
    var isTerminating = false

    func applicationDidFinishLaunching(_: Notification) {
        prune()
        DispatchQueue.main.async { [weak self] in self?.prune() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.prune() }
    }

    func applicationDidBecomeActive(_: Notification) {
        prune()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        beginTermination { [weak sender] allowed in
            sender?.reply(toApplicationShouldTerminate: allowed)
        }
    }

    private func prune() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let undo = Selector(("undo:"))
        let showHelp = Selector(("showHelp:"))
        let helpTitle = NSLocalizedString("Help", tableName: nil, bundle: .init(for: NSApplication.self), comment: "")
        for item in mainMenu.items {
            guard let submenu = item.submenu else { continue }
            let isEdit = submenu.items.contains { $0.action == undo }
            let isHelp = submenu == NSApp.helpMenu
                || submenu.items.contains { $0.action == showHelp }
                || item.title == helpTitle
                || item.title == "Help"
            if isEdit || isHelp { mainMenu.removeItem(item) }
        }
    }
}

/// Makes the Settings window user-resizable. `.windowResizability(.contentMinSize)` lifts
/// the window's maximum-size ceiling, but SwiftUI never inserts `.resizable` into a
/// `Settings` scene's style mask, so the zoom button stays disabled and no edge drag
/// resizes it. Inserting the flag once, as the host view joins the window, supplies the
/// missing half — the same live style-mask seam ``SplashWindowChrome`` relies on below.
private struct SettingsWindowResizable: NSViewRepresentable {
    /// Only ever `insert` into the mask: assigning it wholesale drops `.titled` and
    /// crashes SwiftUI's window management. The hop to the next run-loop turn is what
    /// ``SplashWindowChrome`` does too — mutating the mask synchronously from inside
    /// SwiftUI's own window setup hangs the app before its main window ever appears.
    final class Helper: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.window?.styleMask.insert(.resizable)
            }
        }
    }

    func makeNSView(context _: Context) -> NSView {
        Helper()
    }

    func updateNSView(_: NSView, context _: Context) {}
}

private struct SplashWindowChrome: NSViewRepresentable {
    var isSplash: Bool
    private static let splashSize = NSSize(width: 620, height: 414)

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        view.setFrameSize(.zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if isSplash {
                window.styleMask.remove(.titled)
                window.titlebarAppearsTransparent = true
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                let origin = NSPoint(
                    x: screen.midX - Self.splashSize.width / 2,
                    y: screen.midY - Self.splashSize.height / 2
                )
                window.setFrame(NSRect(origin: origin, size: Self.splashSize), display: true)
            } else {
                window.styleMask.insert(.titled)
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
                window.hasShadow = true
                window.title = "MacAMP"
                let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.45
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(screen, display: true)
                }
            }
        }
    }
}
