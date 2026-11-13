// LoudnessSettingsSection — the loudness pass inside the existing Playback pane.
//
// Structurally a twin of ``AudioAnalysisSettingsSection``: while a pass runs it
// shows a token-tinted `ProgressView`, the live counter, the current track and
// Pause/Resume + Stop; while idle it offers Scan and Re-scan.
//
// The coverage line is `analyzedFraction`, NOT `progressFraction`. The latter
// describes one pass (its total is a start-of-pass snapshot of stale tracks); the
// former describes the library. The copy says "measured", never "complete": a
// permanently undecodable file is retried by every future pass and never counted,
// so this figure can legitimately sit below 100% forever and must not be presented
// as a broken progress bar.
//
// NOTHING HERE RUNS UNLESS PRESSED. The section reads coverage on appear and
// otherwise leaves the pass alone — an import never starts a scan.
import DesignSystem
import SwiftUI
import ViewModels

/// The loudness coverage read-out plus its scan / pause / stop controls.
struct LoudnessSettingsSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var confirmsRescan = false

    var body: some View {
        Section {
            sectionTitle
            PreferenceCaption(text: LoudnessStrings.caption)
            coverageRow
            skippedCaption
            statusRow
        }
        .task { await viewModel.refreshCoverage() }
        .confirmationDialog(
            Text(LoudnessStrings.rescanConfirmTitle),
            isPresented: $confirmsRescan
        ) {
            Button(role: .destructive) {
                viewModel.rescanAll()
            } label: {
                Text(LoudnessStrings.rescanConfirmAction)
            }
            .accessibilityIdentifier("playback.loudnessRescanConfirm")
            Button(role: .cancel) {} label: {
                Text(LoudnessStrings.cancel)
            }
            .accessibilityIdentifier("playback.loudnessRescanCancel")
        } message: {
            Text(LoudnessStrings.rescanConfirmMessage)
        }
    }
}

// MARK: - State surfaces

private extension LoudnessSettingsSection {
    var viewModel: LoudnessScanViewModel {
        environment.loudness.scan
    }

    var sectionTitle: some View {
        Text(LoudnessStrings.section)
            .font(tokens.typography.headline.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
    }

    var coverageRow: some View {
        Text(coverageText)
            .font(tokens.typography.callout.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            .monospacedDigit()
            .accessibilityIdentifier("playback.loudnessCoverage")
    }

    @ViewBuilder
    var skippedCaption: some View {
        if viewModel.failedCount > 0 {
            PreferenceCaption(text: LoudnessStrings.skipped(count: viewModel.failedCount))
        }
    }

    @ViewBuilder
    var statusRow: some View {
        if viewModel.isRunning {
            runningContent
        } else {
            idleContent
        }
    }

    var coverageText: LocalizedStringResource {
        guard viewModel.analyzableTrackCount > 0 else { return LoudnessStrings.empty }
        return LoudnessStrings.coverage(
            percent: viewModel.analyzedFraction.formatted(.percent.precision(.fractionLength(0))),
            analyzed: viewModel.analyzedTrackCount,
            total: viewModel.analyzableTrackCount
        )
    }
}

// MARK: - Running

private extension LoudnessSettingsSection {
    var runningContent: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            progressHeader
            ProgressView(value: viewModel.progressFraction)
                .tint(tokens.colors.accent.resolve(scheme))
                .accessibilityIdentifier("playback.loudnessProgress")
            currentTrackLabel
            runningControls
        }
        .padding(.vertical, tokens.spacing.xxSmall)
    }

    var progressHeader: some View {
        HStack(spacing: tokens.spacing.small) {
            Text(viewModel.isPaused ? LoudnessStrings.paused : LoudnessStrings.running)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Spacer(minLength: tokens.spacing.small)
            // "12 / 40" — a numeric token pair, like a timecode.
            Text(verbatim: viewModel.progressText)
                .font(tokens.typography.caption.font)
                .monospacedDigit()
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
        }
    }

    @ViewBuilder
    var currentTrackLabel: some View {
        if let track = viewModel.currentTrack {
            Text(verbatim: track)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var runningControls: some View {
        HStack(spacing: tokens.spacing.small) {
            pauseResumeButton
            Button(role: .destructive) {
                viewModel.stop()
            } label: {
                Label { Text(EnrichmentStrings.stop) } icon: { Image(systemName: "stop.fill") }
            }
            .accessibilityIdentifier("playback.loudnessStop")
            .pointingHandCursor()
            Spacer()
        }
        .padding(.top, tokens.spacing.xxSmall)
    }

    @ViewBuilder
    var pauseResumeButton: some View {
        if viewModel.isPaused {
            Button {
                viewModel.resume()
            } label: {
                Label { Text(EnrichmentStrings.resume) } icon: { Image(systemName: "play.fill") }
            }
            .accessibilityIdentifier("playback.loudnessResume")
            .pointingHandCursor()
        } else {
            Button {
                viewModel.pause()
            } label: {
                Label { Text(EnrichmentStrings.pause) } icon: { Image(systemName: "pause.fill") }
            }
            .accessibilityIdentifier("playback.loudnessPause")
            .pointingHandCursor()
        }
    }
}

// MARK: - Idle

private extension LoudnessSettingsSection {
    var idleContent: some View {
        HStack(spacing: tokens.spacing.small) {
            Spacer(minLength: 0)
            Button {
                confirmsRescan = true
            } label: {
                Label { Text(LoudnessStrings.rescan) } icon: { Image(systemName: "arrow.clockwise") }
            }
            .accessibilityIdentifier("playback.loudnessRescan")
            .help(LoudnessStrings.rescanHelp)
            .pointingHandCursor()
            Button {
                viewModel.start()
            } label: {
                Label { Text(LoudnessStrings.scan) } icon: { Image(systemName: "waveform.badge.magnifyingglass") }
            }
            .accessibilityIdentifier("playback.loudnessScan")
            .help(LoudnessStrings.scanHelp)
            .pointingHandCursor()
        }
        .padding(.vertical, tokens.spacing.xxSmall)
    }
}
