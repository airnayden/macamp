import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

/// Metrics shared across the main window's split files.
enum MainWindowMetrics {
    /// One height for BOTH the sidebar search bar and the content toolbar, so
    /// their bottom boundaries land on the same line as the content divider —
    /// the two bars live in different ZStack subtrees and cannot align naturally.
    static let topBarHeight: CGFloat = 48
}

struct MainWindowView: View {
    // Members touched by the sibling `MainWindowActions.swift` and
    // `MainWindowToolbar.swift` extensions are `internal` (not `private`),
    // matching the LibraryBrowserView split pattern.
    @Environment(AppEnvironment.self) var environment
    @Environment(AppSettings.self) var settings
    @Environment(NavigationModel.self) var nav
    @Environment(PlayIntent.self) var playIntent
    @Environment(\.designTokens) var tokens
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var isDropTargeted = false
    @State var exportPlaylistId: Int64?
    /// Count (not Bool): overlapping toggles must keep hit-testing suspended
    /// until the LAST animation completes, not the first.
    @State var paneTransitionCount = 0
    @State var showNewPlaylistSheet = false
    @State var showImportPlaylist = false
    @State var importError: String?
    @State var newItemName = ""

    var body: some View {
        @Bindable var nav = nav
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(tokens.colors.separator.resolve(scheme))
                    .frame(height: 0.5)
                mainSplit
                Divider()
                PlayerBarView(showRightPanel: $nav.showRightPanel, onIdentityTap: {
                    withAnimation(.easeInOut(duration: 0.3)) { nav.showNowPlayingOverlay.toggle() }
                }, onProfileTap: {
                    withAnimation(.easeInOut(duration: 0.3)) { nav.showProfileOverlay.toggle() }
                })
            }
            enrichmentProgressBar
                .animation(.easeInOut(duration: tokens.motion.quick), value: environment.enrichmentViewModel.isRunning)
            ToastOverlay()
                .environment(environment.toast)
        }
        .overlay {
            if nav.showEQOverlay {
                ZStack {
                    EQOverlayView(isPresented: $nav.showEQOverlay)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    ZStack {
                        tokens.colors.canvas.resolve(scheme).opacity(0.6)
                        MacAMPBackdrop()
                    }
                }
            }
        }
        .overlay {
            if nav.showNowPlayingOverlay {
                // The backdrop is attached to this stationary wrapper — NOT to the
                // sliding content — so insertion fades it in place while only the
                // content rides `.move`. Attached to the moving view it slides
                // along and re-rasterizes the full-window image every frame.
                ZStack {
                    NowPlayingExpandedView(isPresented: $nav.showNowPlayingOverlay)
                        .transition(.move(edge: .bottom))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { overlayBackdrop }
            }
        }
        .overlay {
            if nav.showProfileOverlay {
                ZStack {
                    ProfileOverlayView(isPresented: $nav.showProfileOverlay)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { overlayBackdrop }
            }
        }
        .background { MacAMPBackdrop() }
        .frame(minWidth: 880, minHeight: 560)
        .tint(tokens.colors.accent.resolve(scheme))
        .focusable()
        // Keeps Space/arrow key handling but suppresses the focus ring: AppKit
        // renders it as an animated window-sized blurred bitmap (profiled at 22%
        // of all main-thread work once the root gained focus), dragging down
        // every animation afterwards.
        .focusEffectDisabled()
        .task {
            try? await environment.playlists.loadInitialPlaylists()
        }
        // Navigating the sidebar while search results are shown means "leave the
        // search" — clearing the query lets the selected destination render
        // instead of forcing the user to empty the field first.
        .onChange(of: nav.sidebar) { _, _ in
            guard isSearchActive else { return }
            searchText = ""
        }
        .onChange(of: environment.profileService.activeProfile.id) { _, activeProfileId in
            let profileId = activeProfileId ?? ProfileRecord.guestID
            nav.resetForProfileSwitch(profileId: profileId, folderOwnership: folderOwnership(for: profileId))
        }
        .onReceive(NotificationCenter.default.publisher(for: .profilePlaybackStateDidRestore)) { notification in
            guard let restoredEnvironment = notification.object as? AppEnvironment,
                  restoredEnvironment === environment,
                  let profileId = notification.userInfo?[ProfilePlaybackRestoreNotification.profileIdKey] as? Int64,
                  environment.profileService.activeProfile.id ?? ProfileRecord.guestID == profileId
            else { return }
            nav.restoreSidebarForProfileSwitch(
                profileId: profileId,
                folderOwnership: folderOwnership(for: profileId)
            )
        }
        .onKeyPress(.space) { handleSpaceKey() }
        .onReceive(NotificationCenter.default.publisher(for: .mediaKeyPressed)) { notification in
            guard let keyCode = notification.userInfo?["keyCode"] as? Int else { return }
            switch keyCode {
            case 16: environment.player.togglePlayPause()
            case 17: environment.player.next()
            case 18: environment.player.previous()
            case 19: environment.player.next()
            case 20: environment.player.previous()
            default: break
            }
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            guard press.modifiers == .command else {
                return handleBareArrowSeek(press.modifiers, forward: true)
            }
            environment.player.next()
            return .handled
        }
        .onKeyPress(.leftArrow, phases: .down) { press in
            guard press.modifiers == .command else {
                return handleBareArrowSeek(press.modifiers, forward: false)
            }
            environment.player.previous()
            return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { press in
            guard press.modifiers == .command else {
                return handleBareArrowVolume(press.modifiers, up: true)
            }
            let current = environment.player.volume
            environment.player.setVolume(min(current + 0.05, 1.0))
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            guard press.modifiers == .command else {
                return handleBareArrowVolume(press.modifiers, up: false)
            }
            let current = environment.player.volume
            environment.player.setVolume(max(current - 0.05, 0.0))
            return .handled
        }
        // The window-level review surface for every contextual AI action. The
        // assistant pane keeps its own `.sheet` for a typed request: the two are
        // driven by different state and can never be raised at once, because the
        // pane and the browsers that own the contextual menus are different sidebar
        // destinations and a raised sheet blocks the menu that would raise the other.
        .sheet(item: $nav.pendingProposal) { proposal in
            ProposalPreviewSheet(proposal: proposal)
        }
        .sheet(isPresented: $showNewPlaylistSheet) {
            newItemNameSheet(
                title: MacAMPStrings.helpNewPlaylist,
                placeholder: MacAMPStrings.helpNewPlaylist
            ) { name in
                Task { try? await environment.playlists.createPlaylist(named: name) }
            }
        }
        .fileImporter(
            isPresented: $showImportPlaylist,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handlePlaylistImport(result)
        }
        .alert(Text(MacAMPStrings.helpImportPlaylist), isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button { importError = nil } label: { Text(MacAMPStrings.okButton) }
        } message: {
            if let importError { Text(verbatim: importError) }
        }
    }

    private func newItemNameSheet(
        title: LocalizedStringResource,
        placeholder: LocalizedStringResource,
        onCreate: @escaping (String) -> Void
    ) -> some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
            TextField(String(localized: placeholder), text: $newItemName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit {
                    guard !newItemName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    onCreate(newItemName)
                    showNewPlaylistSheet = false
                }
            HStack {
                Button(role: .cancel) {
                    showNewPlaylistSheet = false
                } label: {
                    Text(MacAMPStrings.cancelButton)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    guard !newItemName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    onCreate(newItemName)
                    showNewPlaylistSheet = false
                } label: {
                    Text(MacAMPStrings.createButton)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newItemName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The id→path source is the incoming profile's PERSISTED folder-tree selection,
    /// not the live registry: the registry is still scoped to the outgoing profile, so
    /// it cannot resolve the other profile's subfolder id.
    private func folderOwnership(for profileId: Int64) -> FolderSelectionOwnership {
        let rootPaths = environment.libraryAccess.roots.map(\.url.path)
        let selection = FolderTreeStore().load(profileId: profileId).selection
        return FolderSelectionOwnership(
            rootIds: Set(rootPaths.map(FolderSidebarViewModel.stableRootId(forPath:))),
            rootPaths: rootPaths,
            pathForId: { rootId in selection.flatMap { $0.rootId == rootId ? $0.path : nil } }
        )
    }

    private var overlayBackdrop: some View {
        ZStack {
            tokens.colors.canvas.resolve(scheme).opacity(0.97)
            MacAMPBackdrop()
        }
    }
}

// MARK: - Layout

private extension MainWindowView {
    /// Layout tuned from Instruments data — revalidate with a hitch trace before
    /// restructuring. The panes are ZStack siblings sliding via an animated
    /// clipped frame around FIXED-width content (only platform-view origins move
    /// per frame), never structurally inserted (rebuild cost) and never `.offset`
    /// or `.overlay` hosted (both broke AX/XCUITest hit-point resolution). The
    /// detail's padding animates in sync: releasing it in a single instant reflow
    /// produced one 50-80 ms hitch frame per toggle, while the animated reflow
    /// costs ~2-4 ms per frame — affordable since the spectrum view stopped
    /// re-entering window layout (see `InlineSpectrumNSView`).
    var mainSplit: some View {
        ZStack(alignment: .leading) {
            detailColumn
                .padding(.leading, nav.sidebarVisibility == .all ? 240 : 0)
                .padding(.trailing, nav.showRightPanel ? 340 : 0)
            sidebarPane
            rightPane
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    var sidebarPane: some View {
        let visible = nav.sidebarVisibility == .all
        return VStack(spacing: 0) {
            LibrarySearchField(text: $searchText)
            SidebarView(
                folders: environment.libraryFolders.sidebar.nodes,
                onRemoveFolder: { rootId in removeFolder(rootId: rootId) }
            )
        }
        .frame(width: 240)
        .background(.windowBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(tokens.colors.separator.resolve(scheme))
                .frame(width: tokens.spacing.hairline)
        }
        .frame(width: visible ? 240 : 0, alignment: .trailing)
        .clipped()
        .allowsHitTesting(visible && paneTransitionCount == 0)
        .accessibilityHidden(!visible)
        .disabled(!visible)
    }

    var rightPane: some View {
        let visible = nav.showRightPanel
        return RightPanelView()
            .background(.windowBackground)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(tokens.colors.separator.resolve(scheme))
                    .frame(width: tokens.spacing.hairline)
            }
            .frame(width: visible ? 340 : 0, alignment: .leading)
            .clipped()
            .allowsHitTesting(visible && paneTransitionCount == 0)
            .accessibilityHidden(!visible)
            .disabled(!visible)
    }

    var detailColumn: some View {
        VStack(spacing: 0) {
            contentToolbarBar
            Divider()
            contentPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .dropDestination(for: URL.self, action: { urls, _ in
            handleDrop(urls)
        }, isTargeted: { targeted in
            isDropTargeted = targeted
        })
        .overlay { dropOverlay.animation(.easeInOut(duration: 0.15), value: isDropTargeted) }
    }

    @ViewBuilder
    var dropOverlay: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: tokens.radii.medium)
                .strokeBorder(tokens.colors.accent.resolve(scheme), lineWidth: 2)
                .overlay(alignment: .bottom) {
                    Text(MacAMPStrings.dropImportHint)
                        .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
                        .padding(.vertical, tokens.spacing.xSmall)
                        .padding(.horizontal, tokens.spacing.medium)
                        .background(
                            Capsule().fill(tokens.colors.accent.resolve(scheme))
                        )
                        .padding(.bottom, tokens.spacing.large)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

// MARK: - Enrichment activity

private extension MainWindowView {
    @ViewBuilder
    var enrichmentProgressBar: some View {
        let enrichment = environment.enrichmentViewModel
        if enrichment.isRunning {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(tokens.colors.accent.resolve(scheme).opacity(0.18))
                    Rectangle()
                        .fill(tokens.colors.accent.resolve(scheme))
                        .frame(width: proxy.size.width * clampedFraction(enrichment.progressFraction))
                        .animation(.easeInOut(duration: tokens.motion.standard), value: enrichment.progressFraction)
                }
            }
            .frame(height: tokens.spacing.hairline * 2)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }

    func clampedFraction(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

#Preview {
    MainWindowView()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .environment(NavigationModel())
        .environment(PlayIntent())
        .designTokens(.standard)
}
