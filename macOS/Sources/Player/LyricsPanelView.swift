// LyricsPanelView — synced-lyrics panel bound to `LyricsViewModel`.
//
// On a track change it resolves lyrics through the view model (offline by
// default — online fetch stays opt-in) and, on a light timer, advances the
// `LyricsViewModel` highlight from the player's elapsed time. The active line is
// emphasized (accent-weight, full opacity) while the rest dim, and the panel
// auto-scrolls to keep the active line centered. The scroll + highlight
// transitions honor reduce-motion. Lyric text is track DATA → `Text(verbatim:)`.
import DesignSystem
import Lyrics
import Services
import SwiftUI
import ViewModels

/// A karaoke-style synced-lyrics panel for the currently-playing track, which the
/// Lyrics browser can temporarily retarget at any other track (see ``previewPane``).
struct LyricsPanelView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(NavigationModel.self) private var nav
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The hosting pane marks itself `.disabled` while hidden; gating the ticker
    /// on it stops this always-mounted panel from driving 0.5 s progress ticks
    /// inside a zero-width clipped pane.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Group {
            if previewTrack != nil {
                previewPane
            } else {
                nowPlayingPane
            }
        }
        .onChange(of: isPreviewNowPlaying, initial: true) { _, isNowPlaying in
            if isNowPlaying { environment.lyricsBrowser.clearPreview() }
        }
        .onChange(of: isBrowsingLyrics, initial: true) { _, isBrowsing in
            guard !isBrowsing, environment.lyricsBrowser.previewTrack != nil else { return }
            environment.lyricsBrowser.clearPreview()
        }
    }

    /// The preview belongs to the Lyrics sidebar section, so LEAVING that section is
    /// what dismisses it — the pane itself is lyrics text and nothing else, with no
    /// back button to press.
    ///
    /// Read with `initial: true` as well as on change: this panel structurally
    /// unmounts while another right-panel tab is selected, so a section change made
    /// in the meantime is only observable on the next mount.
    private var isBrowsingLyrics: Bool {
        nav.sidebar == .fixed(.lyrics)
    }

    /// Masks a preview of the ALREADY-playing track to `nil` (the live pane is the
    /// better view of it) with no render flash; `body`'s `onChange` then drops the
    /// stale preview, so it cannot reappear on the next skip.
    private var previewTrack: TrackRef? {
        isPreviewNowPlaying ? nil : environment.lyricsBrowser.previewTrack
    }

    private var isPreviewNowPlaying: Bool {
        guard let preview = environment.lyricsBrowser.previewTrack else { return false }
        return preview.trackID != nil && preview.trackID == environment.player.currentTrack?.trackID
    }

    private var nowPlayingPane: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: environment.player.currentTrack?.id) { resolveLyrics() }
            .onActiveTick(isActive: environment.player.isPlaying && isEnabled, every: 0.5) {
                environment.player.refreshProgress()
            }
            .onChange(of: environment.player.elapsed) { _, _ in syncHighlight() }
            .onChange(of: environment.lyrics.lines.count) { _, _ in syncHighlight() }
    }

    @ViewBuilder
    private var content: some View {
        if environment.lyrics.isLoading {
            fetchProgress
                .synthwaveEmptyBackground()
        } else if environment.lyrics.lines.isEmpty {
            VStack(spacing: tokens.spacing.medium) {
                StateView(
                    systemImage: "quote.bubble",
                    title: MacAMPStrings.lyricsEmptyTitle,
                    message: MacAMPStrings.lyricsEmptyMessage
                )
                if environment.player.currentTrack != nil {
                    if settings.onlineLyricsEnabled {
                        fetchControls(for: environment.lyrics) { resolveLyrics(explicit: true) }
                    } else {
                        Text(PreferencesStrings.onlineLyricsDisabledHint)
                            .font(tokens.typography.caption.font)
                            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, tokens.spacing.large)
                    }
                }
            }
            .synthwaveEmptyBackground()
        } else {
            lyricsScroll
        }
    }

    private func fetchControls(for model: LyricsViewModel, action: @escaping () -> Void) -> some View {
        VStack(spacing: tokens.spacing.xSmall) {
            Button(action: action) {
                Label { Text(MacAMPStrings.lyricsFetch) } icon: {
                    Image(systemName: "arrow.clockwise")
                }
                .font(tokens.typography.callout.font)
            }
            .buttonStyle(.borderedProminent)
            .tint(tokens.colors.accent.resolve(scheme))
            .disabled(model.isLoading)
            .pointingHandCursor()
            .accessibilityIdentifier("lyrics.fetch")
            fetchStatus(for: model)
        }
    }

    private var fetchProgress: some View {
        ProgressView {
            Text(MacAMPStrings.lyricsFetching)
                .font(tokens.typography.callout.font)
        }
        .controlSize(.small)
        .accessibilityIdentifier("lyrics.fetch.progress")
    }

    @ViewBuilder
    private func fetchStatus(for model: LyricsViewModel) -> some View {
        switch model.fetchOutcome {
        case .loading:
            fetchProgress
        case .noMatch:
            fetchStatusText(MacAMPStrings.lyricsFetchNoMatch)
        case .failed:
            fetchStatusText(failureText(model.fetchFailure))
                .accessibilityIdentifier("lyrics.fetch.failure")
        case .idle, .found:
            EmptyView()
        }
    }

    private func failureText(_ failure: LyricsFetchFailure?) -> LocalizedStringResource {
        switch failure {
        case let .serviceStatus(status):
            MacAMPStrings.lyricsFetchHTTPFailure(
                status,
                reason: HTTPURLResponse.localizedString(forStatusCode: status)
            )
        case .invalidRequest: MacAMPStrings.lyricsFetchInvalidRequest
        case .invalidResponse: MacAMPStrings.lyricsFetchInvalidResponse
        case let .network(code, message): MacAMPStrings.lyricsFetchNetworkFailure(code, reason: message)
        case let .other(message): MacAMPStrings.lyricsFetchFailureDetail(message)
        case nil: MacAMPStrings.lyricsFetchFailed
        }
    }

    private func fetchStatusText(_ resource: LocalizedStringResource) -> some View {
        Text(resource)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, tokens.spacing.large)
    }

    private var lyricsScroll: some View {
        LyricsScrollContent()
    }
}

// MARK: - Preview mode

private extension LyricsPanelView {
    /// The previewed track's lyrics text, and deliberately nothing else — no
    /// header, no track chrome, no back button.
    var previewPane: some View {
        previewBody
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The previewed track is not playing, so its lines render STATICALLY — no
    /// ticker, no active-line highlight, no auto-scroll.
    ///
    /// They render as ONE `Text` built from a SINGLE read of the live `@Observable`
    /// `lines`. The previous version fanned them out over
    /// `ForEach(model.lines.indices, id: \.self)` and re-subscripted the LIVE array
    /// inside the row closure: when a newer `resolve()` swapped in a SHORTER array,
    /// Observation re-ran a row body with its now-stale index before the `ForEach`
    /// re-read its collection, and the subscript trapped out of bounds — a shipped
    /// crash. With no index, no row closure and no `ForEach`, that is now
    /// structurally impossible.
    @ViewBuilder
    var previewBody: some View {
        let model = environment.lyricsBrowser.previewLyrics
        let lines = model.lines
        if model.isLoading {
            fetchProgress
                .synthwaveEmptyBackground()
        } else if lines.isEmpty {
            VStack(spacing: tokens.spacing.medium) {
                StateView(
                    systemImage: "quote.bubble",
                    title: MacAMPStrings.lyricsEmptyTitle,
                    message: MacAMPStrings.lyricsEmptyMessage
                )
                if settings.onlineLyricsEnabled, let track = previewTrack {
                    fetchControls(for: model) {
                        environment.lyricsBrowser.select(track, options: .online)
                    }
                }
            }
            .synthwaveEmptyBackground()
        } else {
            ScrollView {
                Text(verbatim: previewText(lines))
                    .font(tokens.typography.body.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(tokens.spacing.xxSmall)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, tokens.spacing.large)
                    .padding(.horizontal, tokens.spacing.large)
            }
        }
    }

    /// Blank lines become a space so they keep their line height, exactly as the
    /// per-line rows this replaced did.
    func previewText(_ lines: [LyricLine]) -> String {
        lines.map { $0.text.isEmpty ? " " : $0.text }.joined(separator: "\n")
    }
}

/// The scrolling line list, split out so it observes ONLY the lyrics model
/// (`lines` + `activeLineIndex`). The parent panel's body re-evaluates on every
/// 0.5 s `elapsed` mutation (its `onChange` drives the highlight); keeping the
/// line list out of that dependency stops the whole panel re-rendering — and
/// hitching — twice a second while playing.
private struct LyricsScrollContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: tokens.spacing.small) {
                    // `lines` is a VALUE snapshot the row closure captures, so
                    // `lines[index]` can never disagree with the `lines.indices` the
                    // same snapshot produced — even when the live model swaps in a
                    // shorter array mid-update. NEVER subscript
                    // `environment.lyrics.lines` directly in here: that is the
                    // out-of-bounds trap `previewBody` was crashing on.
                    let lines = environment.lyrics.lines
                    ForEach(lines.indices, id: \.self) { index in
                        lineView(index, lines[index])
                    }
                }
                .padding(.vertical, tokens.spacing.xxxLarge)
                .padding(.horizontal, tokens.spacing.large)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: environment.lyrics.activeLineIndex) { _, newIndex in
                scroll(proxy, to: newIndex)
            }
        }
    }

    private func lineView(_ index: Int, _ line: LyricLine) -> some View {
        let isActive = index == environment.lyrics.activeLineIndex
        let role = isActive ? tokens.typography.titleLarge : tokens.typography.titleMedium
        let color = isActive ? tokens.colors.accent : tokens.colors.textSecondary
        return Text(verbatim: displayText(line))
            .font(role.font)
            .foregroundStyle(color.resolve(scheme))
            .opacity(isActive ? 1 : 0.65)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, tokens.spacing.xxSmall)
            .id(index)
            .animation(highlightAnimation, value: isActive)
    }

    private func scroll(_ proxy: ScrollViewProxy, to index: Int?) {
        guard let index else { return }
        if reduceMotion {
            proxy.scrollTo(index, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: tokens.motion.standard)) {
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private var highlightAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: tokens.motion.quick)
    }

    private func displayText(_ line: LyricLine) -> String {
        line.text.isEmpty ? " " : line.text
    }
}

// MARK: - Behavior

private extension LyricsPanelView {
    /// `album` stays `nil` because ``TrackRef`` carries no album title — the queue
    /// element is deliberately minimal. LRCLIB's exact-signature lookup can miss
    /// without it, which is precisely what the client's `/api/search` duration-
    /// matched fallback covers.
    func resolveLyrics(explicit: Bool = false) {
        guard let track = environment.player.currentTrack else {
            environment.lyrics.clear()
            return
        }
        let request = LyricsRequest(
            trackURL: track.url,
            title: track.title,
            artist: track.artist,
            album: nil,
            duration: track.duration
        )
        environment.lyrics.resolve(
            request: request,
            options: settings.onlineLyricsEnabled ? .online : .offline,
            explicit: explicit
        )
    }

    func syncHighlight() {
        // The active line tracks `elapsed` reactively (via `onChange`), NOT the
        // ticker — so a seek while paused still resyncs the highlight, and it
        // also resyncs when the line set finishes loading. The ticker only
        // advances `elapsed` (`refreshProgress`) while playing.
        environment.lyrics.updateHighlight(at: environment.player.elapsed)
    }
}

#Preview("Lyrics · Light") {
    LyricsPanelView()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .environment(NavigationModel())
        .designTokens(.standard)
        .frame(width: 420, height: 520)
        .preferredColorScheme(.light)
}

#Preview("Lyrics · Dark") {
    LyricsPanelView()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .environment(NavigationModel())
        .designTokens(.standard)
        .frame(width: 420, height: 520)
        .preferredColorScheme(.dark)
}
