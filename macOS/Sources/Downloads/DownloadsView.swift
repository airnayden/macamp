// DownloadsView — the detail pane for `SidebarDestination.fixed(.downloads)`.
//
// A container over two tabs: the live ``DownloadsQueueView`` (unchanged) and the
// ``DownloadsHistoryView`` log of finished downloads. It also owns the ONE presentation
// point for the paste sheet. The sheet's flag lives on ``NavigationModel`` rather than
// here because two surfaces raise it — the pane's own toolbar `+` and the File-menu
// item, which fires from the app scene where this view may not even be on screen yet. A
// window-level slot means one `.sheet` and one entry path, the same reasoning
// `pendingProposal` records for the AI review sheet.
//
// ── THE TAB SELECTION IS LOCAL; THE HISTORY WINDOW OUTLIVES IT ──────────────
//
// `tab` is `@State` here, so leaving the Downloads destination and coming back reopens
// on Queue — the live surface is the right landing place, and a persisted tab would put
// a listener who came to watch a transfer in front of a log.
//
// ``history`` is `@State` for the opposite reason: switching tabs tears the History view
// down, so a model owned by that view would throw away every page the listener had
// scrolled. Holding it here means the window survives and only its `.task` reload
// re-runs. It is built in `.task` rather than in `init` because the repository comes
// from `AppEnvironment`, which a `View`'s initializer cannot read — and never from
// `body`, because assigning state during a body evaluation is what produces a different
// instance per pass.
//
// It is deliberately NOT an `AppEnvironment` property: nothing outside this pane reads
// download history, and a model owned by the only screen that renders it needs no
// composition root. The REPOSITORY is the shared thing, and it is built over
// `environment.database` — the same handle `wireDownloadSeams` gives the recorder.
//
// This file constructs no `Process` and no `URLSession` — `macOS/Sources/Downloads` is
// scanned wholesale by `scripts/check-downloader-boundary.sh`.
import DesignSystem
import Foundation
import os
import Persistence
import SwiftUI
import ViewModels

/// Which half of the Downloads pane is on screen.
enum DownloadsTab: String, CaseIterable, Identifiable {
    case queue
    case history

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .queue: MacAMPStrings.downloadsTabQueue
        case .history: MacAMPStrings.downloadsTabHistory
        }
    }
}

struct DownloadsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(NavigationModel.self) private var nav
    @Environment(\.designTokens) private var tokens

    @State private var tab: DownloadsTab = .queue
    @State private var history: DownloadHistoryViewModel?

    private static let log = Logger(subsystem: "si.macamp.MacAMP", category: "downloads.history")

    var body: some View {
        @Bindable var nav = nav
        return Group {
            if let model = environment.downloadsModel {
                loaded(model)
                    .environment(\.downloadThumbnails, environment.downloadThumbnails)
                    .sheet(isPresented: $nav.showDownloadsPasteSheet) {
                        DownloadsPasteSheet(model: model)
                    }
            } else {
                // Only reachable in the sliver before `connectDownloads` has run (or in
                // a preview built without it): the queue is assembled during `live()`,
                // so the main window normally never sees this branch.
                StateView(
                    systemImage: "arrow.down.circle",
                    title: MacAMPStrings.downloadsQueueUnavailableTitle,
                    message: MacAMPStrings.downloadsQueueUnavailableMessage
                )
                .synthwaveEmptyBackground()
            }
        }
        .task { buildHistoryIfNeeded() }
    }
}

// MARK: - Tabs

private extension DownloadsView {
    func loaded(_ model: DownloadsViewModel) -> some View {
        VStack(spacing: 0) {
            tabPicker
            Divider()
            pane(model)
        }
    }

    var tabPicker: some View {
        Picker(selection: $tab) {
            ForEach(DownloadsTab.allCases) { item in
                // Per-segment identifiers (the `RightPanelView` precedent) so a UI test
                // selects a tab by its stable raw value rather than by its translated
                // label, which would make the suite depend on the run's app language.
                Text(item.label)
                    .tag(item)
                    .accessibilityIdentifier("downloads.tabs.\(item.rawValue)")
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 320)
        .padding(.horizontal, tokens.spacing.large)
        .padding(.top, tokens.spacing.small)
        .padding(.bottom, tokens.spacing.xSmall)
        .pointingHandCursor()
        .help(Text(MacAMPStrings.downloadsTabsLabel))
        .accessibilityLabel(Text(MacAMPStrings.downloadsTabsLabel))
        .accessibilityIdentifier("downloads.tabs")
    }

    @ViewBuilder
    func pane(_ model: DownloadsViewModel) -> some View {
        switch tab {
        case .queue:
            DownloadsQueueView(model: model)
        case .history:
            if let history {
                DownloadsHistoryView(model: history, revision: environment.downloadHistoryRevision) { entry in
                    redownload(entry, from: history, using: model)
                }
            } else {
                // The container's `.task` fills this in before the tab control is
                // reachable, so this is the same one-frame sliver the unavailable-queue
                // branch above covers.
                StateView.loading()
                    .synthwaveEmptyBackground()
            }
        }
    }
}

// MARK: - History wiring

private extension DownloadsView {
    func buildHistoryIfNeeded() {
        guard history == nil else { return }
        history = DownloadHistoryViewModel(repository: DownloadHistoryRepository(environment.database))
    }

    /// Queues the link again through the ordinary paste path and shows the Queue tab,
    /// which is where the result of the click actually becomes visible. Dedup is the
    /// queue's own: a link already in flight quietly adds nothing.
    func redownload(
        _ entry: DownloadHistoryRecord,
        from history: DownloadHistoryViewModel,
        using model: DownloadsViewModel
    ) {
        if entry.failureReason == nil {
            guard let url = URL(string: entry.sourceURL) else { return }
            tab = .queue
            Task { _ = await model.enqueue(urls: [url]) }
        } else {
            Task {
                do {
                    if try await history.retry(entry, using: model) { tab = .queue }
                } catch {
                    // A retry was queued, but forgetting the previous attempt failed.
                    tab = .queue
                    Self.log.error("Could not remove retried download: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

#Preview {
    DownloadsView()
        .environment(AppEnvironment.preview())
        .environment(NavigationModel())
        .designTokens(.standard)
        .frame(width: 720, height: 480)
}
