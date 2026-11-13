// LyricsView — the synced-lyrics sheet, bound to `LyricsViewModel`.
//
// On presentation it resolves lyrics through the view model (offline by default —
// online fetch stays opt-in) and, on a light timer, advances the highlight from
// the player's elapsed time. The active line is emphasized (accent weight, full
// opacity) while the rest dim, and the panel auto-scrolls to keep the active line
// centered. Scroll + highlight transitions honor reduce-motion. Lyric text is
// track DATA → `Text(verbatim:)`.
import DesignSystem
import Lyrics
import SwiftUI

/// A karaoke-style synced-lyrics sheet for the currently-playing track.
struct LyricsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(Text(MacAMPStrings.lyricsTitle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { doneButton }
                }
                .task(id: environment.player.currentTrack?.id) { resolveLyrics() }
                .onActiveTick(isActive: environment.player.isPlaying, every: 0.2) {
                    environment.player.refreshProgress()
                }
                .onChange(of: environment.player.elapsed) { _, _ in syncHighlight() }
                .onChange(of: environment.lyrics.lines.count) { _, _ in syncHighlight() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if environment.lyrics.isLoading {
            StateView.loading()
        } else if environment.lyrics.lines.isEmpty {
            StateView(
                systemImage: "quote.bubble",
                title: MacAMPStrings.lyricsEmptyTitle,
                message: MacAMPStrings.lyricsEmptyMessage
            )
        } else {
            lyricsScroll
        }
    }

    private var lyricsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: tokens.spacing.small) {
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
        let color = isActive ? tokens.colors.textPrimary : tokens.colors.textTertiary
        return Text(verbatim: displayText(line))
            .font(role.font)
            .foregroundStyle(color.resolve(scheme))
            .opacity(isActive ? 1 : 0.5)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, tokens.spacing.xxSmall)
            .id(index)
            .animation(highlightAnimation, value: isActive)
    }

    private var doneButton: some View {
        Button { dismiss() } label: {
            Text(MacAMPStrings.done)
        }
    }
}

// MARK: - Behavior

private extension LyricsView {
    func resolveLyrics() {
        guard let track = environment.player.currentTrack else { return }
        let request = LyricsRequest(
            trackURL: track.url,
            title: track.title,
            artist: track.artist,
            album: nil,
            duration: track.duration
        )
        environment.lyrics.resolve(request: request)
    }

    func syncHighlight() {
        // The active line tracks `elapsed` reactively (via `onChange`), NOT the
        // ticker — so a seek while paused still resyncs the highlight, and it
        // also resyncs when the line set finishes loading. The ticker only
        // advances `elapsed` (`refreshProgress`) while playing.
        environment.lyrics.updateHighlight(at: environment.player.elapsed)
    }

    func scroll(_ proxy: ScrollViewProxy, to index: Int?) {
        guard let index else { return }
        if reduceMotion {
            proxy.scrollTo(index, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: tokens.motion.standard)) {
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    var highlightAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: tokens.motion.quick)
    }

    func displayText(_ line: LyricLine) -> String {
        line.text.isEmpty ? " " : line.text
    }
}

#Preview {
    LyricsView()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
}
