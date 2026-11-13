// KaraokeQueueView — the sidebar `.karaokeQueue` detail: the live karaoke render
// queue. Shows the in-flight render (title/artist + a determinate progress bar) and
// the pending items (drag-reorderable, removable via context menu), plus a
// pause/resume control in the pane header.
//
// Backed by the wire-agnostic `KaraokeQueueStore` (membership + progress, projected
// from the render service's `onQueueChanged`/`onProgress` seams by the composition
// root) and `KaraokeQueueViewModel` (resolves display rows for the active profile).
// Rows re-resolve on membership (`store.version`) and profile changes via
// `.task(id:)`. Every queue mutation goes through `environment.karaokeRender`
// (`@MainActor`) — pause/resume, reorder, remove.
import DesignSystem
import Persistence
import Separation
import SwiftUI
import ViewModels

struct KaraokeQueueView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var model: KaraokeQueueViewModel?

    var body: some View {
        content
            .task(id: loadKey) { await load() }
    }

    private var store: KaraokeQueueStore {
        environment.karaokeQueueStore
    }

    /// No in-flight item and nothing pending — gates both the empty placeholder and
    /// the disabled state of the header control.
    private var isQueueEmpty: Bool {
        store.currentPath == nil && store.pendingPaths.isEmpty
    }

    private var activeProfileId: Int64 {
        environment.profileService.activeProfile.id ?? ProfileRecord.guestID
    }

    /// Re-keys `.task` on a profile switch AND on a membership change (`version`
    /// bumps only when the current/pending/paused set changes, never on progress
    /// ticks), so rows re-resolve exactly when they can differ.
    private var loadKey: KaraokeQueueLoadKey {
        KaraokeQueueLoadKey(profileId: activeProfileId, version: store.version)
    }
}

private struct KaraokeQueueLoadKey: Equatable {
    let profileId: Int64
    let version: Int
}

// MARK: - Content

private extension KaraokeQueueView {
    var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            queueBody
        }
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
    }

    var header: some View {
        HStack(spacing: 0) {
            Spacer()
            pauseResumeButton
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.small)
    }

    /// The queue's header transport control. All three states derive purely from the
    /// store, so the icon always reflects reality (no manual refresh needed):
    /// - `store.isWorking` (an item in flight AND not paused) → `pause.circle` + `pause()`.
    /// - has work but not working — idle-with-pending OR paused-with-current →
    ///   `play.circle` + `resume()`.
    /// - `isQueueEmpty` (nothing in flight, nothing pending) → disabled + greyed.
    ///
    /// Disk-full is surfaced via a TOAST only. When a render hits disk-full the service
    /// latches internally and requeues the failed track, but ``KaraokeQueueSnapshot``
    /// carries no explicit `stopped` flag — so a disk-full-stopped queue still reads here
    /// as an ordinary paused/idle queue and this button simply shows `play.circle` (a tap
    /// `resume()`s — the retry). That is intentional: the toast is the sole disk-full
    /// signal, and the button deliberately has no distinct "stopped" appearance.
    @ViewBuilder
    var pauseResumeButton: some View {
        let working = store.isWorking
        let label = working ? MacAMPStrings.karaokeQueuePause : MacAMPStrings.karaokeQueueResume
        let button = Button {
            if working {
                environment.karaokeRender?.pause()
            } else {
                environment.karaokeRender?.resume()
            }
        } label: {
            Image(systemName: working ? "pause.circle" : "play.circle")
                .font(tokens.typography.titleMedium.font)
                .foregroundStyle(
                    isQueueEmpty
                        ? tokens.colors.textDisabled.resolve(scheme)
                        : tokens.colors.accent.resolve(scheme)
                )
        }
        .buttonStyle(.plain)
        .disabled(isQueueEmpty)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("karaokeQueue.pauseButton")

        if isQueueEmpty {
            button
        } else {
            button.pointingHandCursor()
        }
    }

    @ViewBuilder
    var queueBody: some View {
        if isQueueEmpty {
            emptyState
        } else {
            queueList
        }
    }

    var emptyState: some View {
        StateView(
            systemImage: "list.bullet.clipboard",
            title: MacAMPStrings.karaokeQueueEmptyTitle,
            message: MacAMPStrings.karaokeQueueEmptyMessage
        )
        .synthwaveEmptyBackground()
    }

    var queueList: some View {
        List {
            if let currentRow = model?.currentRow {
                Section {
                    currentItemRow(currentRow)
                } header: {
                    Text(MacAMPStrings.karaokeQueueNowRenderingHeader)
                }
            }
            if let pendingRows = model?.pendingRows, !pendingRows.isEmpty {
                Section {
                    ForEach(pendingRows, id: \.track.id) { pendingRow($0) }
                        .onMove { source, destination in
                            movePending(from: source, to: destination)
                        }
                } header: {
                    Text(MacAMPStrings.karaokeQueuePendingHeader)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Rows

private extension KaraokeQueueView {
    func currentItemRow(_ row: ProfileScopedTrack) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            HStack(spacing: tokens.spacing.small) {
                trackLabel(row)
                Spacer(minLength: 0)
                KaraokeQueueRowButton(
                    systemImage: "stop.fill",
                    label: MacAMPStrings.karaokeQueueStop,
                    accessibilityID: "karaokeQueue.row.stop"
                ) {
                    environment.karaokeRender?.stopCurrent()
                }
            }
            KaraokeQueueProgressBar()
            Text(MacAMPStrings.karaokeQueueRenderingCaption)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
        }
        .padding(.vertical, tokens.spacing.xxSmall)
    }

    func pendingRow(_ row: ProfileScopedTrack) -> some View {
        HStack(spacing: tokens.spacing.small) {
            trackLabel(row)
            Spacer(minLength: 0)
            KaraokeQueueRowButton(
                systemImage: "play.fill",
                label: MacAMPStrings.karaokeQueueStartNow,
                accessibilityID: "karaokeQueue.row.startNow"
            ) {
                environment.karaokeRender?.startNow(URL(fileURLWithPath: row.track.filePath))
            }
        }
        .padding(.vertical, tokens.spacing.xxSmall)
        .contextMenu {
            Button(role: .destructive) {
                removePending(row)
            } label: {
                Label {
                    Text(MacAMPStrings.karaokeQueueRemove)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    func trackLabel(_ row: ProfileScopedTrack) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.hairline * 2) {
            Text(verbatim: row.track.title ?? row.track.filePath)
                .font(tokens.typography.body.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
            if let artist = row.track.artistName {
                Text(verbatim: artist)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Loading + mutations

private extension KaraokeQueueView {
    func load() async {
        if model == nil {
            model = KaraokeQueueViewModel(
                repository: TrackRepository(environment.database),
                activeProfileId: activeProfileId
            )
        }
        model?.activeProfileId = activeProfileId
        try? await model?.resolve(currentPath: store.currentPath, pendingPaths: store.pendingPaths)
    }

    /// Maps SwiftUI's insert-before `.onMove` offset to the render service's
    /// final-position index and forwards the moved pending item's source URL. The
    /// service reorders its own pending array and re-emits the queue snapshot, so the
    /// list settles to the new order through the store.
    func movePending(from source: IndexSet, to destination: Int) {
        guard let rows = model?.pendingRows, let sourceIndex = source.first,
              sourceIndex < rows.count
        else { return }
        let finalIndex = destination > sourceIndex ? destination - 1 : destination
        let url = URL(fileURLWithPath: rows[sourceIndex].track.filePath)
        environment.karaokeRender?.movePending(url, to: finalIndex)
    }

    func removePending(_ row: ProfileScopedTrack) {
        environment.karaokeRender?.removePending(URL(fileURLWithPath: row.track.filePath))
    }
}

// MARK: - Row control

/// A borderless inline row control for the karaoke queue (start-now on a pending
/// row, stop on the in-flight row). Mirrors `KaraokeRenderButton`'s restrained
/// idiom: `.plain` style, tertiary by default and accent on hover, with a
/// `Rectangle` hit shape so a click fires the action without selecting the row.
private struct KaraokeQueueRowButton: View {
    let systemImage: String
    let label: LocalizedStringResource
    let accessibilityID: String
    let action: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(tokens.typography.caption.font)
                .foregroundStyle(
                    isHovered
                        ? tokens.colors.accent.resolve(scheme)
                        : tokens.colors.textTertiary.resolve(scheme)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(accessibilityID)
        .pointingHandCursor()
    }
}

// MARK: - Progress leaf

/// A leaf that reads only `KaraokeQueueStore.currentProgress`, so the in-flight
/// item's progress bar re-renders on progress ticks without churning the queue
/// layout (SKILL macOS UI perf rule 3 — scope high-frequency reads into a leaf).
private struct KaraokeQueueProgressBar: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ProgressView(value: environment.karaokeQueueStore.currentProgress)
            .tint(tokens.colors.accent.resolve(scheme))
    }
}

// MARK: - Previews

#if DEBUG
    private struct KaraokeQueueFixture {
        let path: String
        let songTitle: String
        let artist: String
    }

    private extension AppEnvironment {
        /// Seeds the preview database with the queue's tracks and populates the
        /// karaoke queue store so the queue view renders a current + pending state.
        static func karaokeQueuePreview(
            current: KaraokeQueueFixture?,
            pending: [KaraokeQueueFixture],
            paused: Bool,
            progress: Double
        ) -> AppEnvironment {
            let environment = AppEnvironment.preview()
            let fixtures = (current.map { [$0] } ?? []) + pending
            try? environment.database.writer.write { database in
                for fixture in fixtures {
                    var record = TrackRecord(
                        filePath: fixture.path,
                        title: fixture.songTitle,
                        sortTitle: fixture.songTitle.lowercased(),
                        artistName: fixture.artist,
                        duration: 210,
                        availability: .present
                    )
                    try record.insert(database)
                }
            }
            environment.karaokeQueueStore.ingest(snapshot: KaraokeQueueSnapshot(
                currentURL: current.map { URL(fileURLWithPath: $0.path) },
                pendingURLs: pending.map { URL(fileURLWithPath: $0.path) },
                isPaused: paused
            ))
            if let current {
                environment.karaokeQueueStore.ingestProgress(
                    url: URL(fileURLWithPath: current.path),
                    fraction: progress
                )
            }
            return environment
        }
    }

    #Preview("Empty") {
        KaraokeQueueView()
            .environment(AppEnvironment.preview())
            .designTokens(.standard)
            .frame(width: 720, height: 480)
    }

    #Preview("Current + pending") {
        KaraokeQueueView()
            .environment(AppEnvironment.karaokeQueuePreview(
                current: KaraokeQueueFixture(path: "/music/aurora.flac", songTitle: "Aurora Anthem", artist: "Nova"),
                pending: [
                    KaraokeQueueFixture(path: "/music/zephyr.flac", songTitle: "Zephyr Waltz", artist: "Nova"),
                    KaraokeQueueFixture(path: "/music/ember.flac", songTitle: "Ember Drift", artist: "Halcyon"),
                ],
                paused: false,
                progress: 0.45
            ))
            .designTokens(.standard)
            .frame(width: 720, height: 480)
    }

    #Preview("Paused") {
        KaraokeQueueView()
            .environment(AppEnvironment.karaokeQueuePreview(
                current: KaraokeQueueFixture(path: "/music/aurora.flac", songTitle: "Aurora Anthem", artist: "Nova"),
                pending: [
                    KaraokeQueueFixture(path: "/music/zephyr.flac", songTitle: "Zephyr Waltz", artist: "Nova"),
                ],
                paused: true,
                progress: 0.2
            ))
            .designTokens(.standard)
            .frame(width: 720, height: 480)
    }
#endif
