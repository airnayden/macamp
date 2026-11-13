// AudioAnalysisSettingsSection — the opt-in audio-feature pass in the Intelligence pane.
//
// Structurally a twin of `EnrichmentSettingsSection`: while a pass runs it shows a
// token-tinted `ProgressView`, the live counter, the current track and
// Pause/Resume + Stop; while idle it offers a single start action. Control flows
// through the observable `AudioAnalysisViewModel`, which is reached through
// `AppEnvironment.intelligence` — and is therefore ABSENT exactly when the
// Intelligence switch is off. That is the whole disabled-state implementation:
// there is no separate flag to read, because with the feature off there is no
// analysis service in the process to drive.
//
// The coverage line is `analyzedFraction`, NOT `progressFraction`. The latter
// describes one pass (its total is a start-of-pass snapshot of stale tracks); the
// former describes the library. The copy says "analyzed", never "complete": a
// permanently undecodable file is retried by every future pass and never counted,
// so this figure can legitimately sit below 100% forever and must not be presented
// as a broken progress bar.
//
// TWO start actions, and the difference is the whole reason the second exists.
// "Analyze Library" is fingerprint-driven and therefore correctly does NOTHING once
// coverage is full — which leaves a listener who believes a measurement is wrong
// with no way to act. "Re-analyze Library" discards every cached row first, behind a
// destructive confirmation whose copy says plainly that it decodes every file again
// and can take a long time.
import DesignSystem
import SwiftUI
import ViewModels

/// The audio-analysis coverage readout plus its start/pause/stop controls.
struct AudioAnalysisSettingsSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var confirmsRescan = false

    var body: some View {
        Section {
            sectionTitle
            PreferenceCaption(text: PreferencesStrings.intelligenceAnalysisCaption)
            coverageRow
            skippedCaption
            statusRow
        }
        .task { await viewModel?.refreshAnalyzedFraction() }
        .confirmationDialog(
            Text(PreferencesStrings.intelligenceAnalysisRescanConfirmTitle),
            isPresented: $confirmsRescan
        ) {
            Button(role: .destructive) {
                viewModel?.reanalyzeAll()
            } label: {
                Text(PreferencesStrings.intelligenceAnalysisRescanConfirmAction)
            }
            .accessibilityIdentifier("intelligence.analysisRescanConfirm")
            Button(role: .cancel) {} label: {
                Text(PreferencesStrings.intelligenceAnalysisRescanCancel)
            }
            .accessibilityIdentifier("intelligence.analysisRescanCancel")
        } message: {
            Text(PreferencesStrings.intelligenceAnalysisRescanConfirmMessage)
        }
    }
}

// MARK: - State surfaces

private extension AudioAnalysisSettingsSection {
    /// `nil` whenever the Intelligence switch is off — nothing was constructed.
    var viewModel: AudioAnalysisViewModel? {
        environment.intelligence?.audioAnalysis
    }

    var sectionTitle: some View {
        Text(PreferencesStrings.intelligenceAnalysisSection)
            .font(tokens.typography.headline.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
    }

    @ViewBuilder
    var coverageRow: some View {
        if let viewModel {
            Text(coverage(viewModel))
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .monospacedDigit()
                .accessibilityIdentifier("intelligence.analysisCoverage")
        }
    }

    @ViewBuilder
    var skippedCaption: some View {
        if let viewModel, viewModel.failedCount > 0 {
            PreferenceCaption(
                text: PreferencesStrings.intelligenceAnalysisSkipped(count: viewModel.failedCount)
            )
        }
    }

    @ViewBuilder
    var statusRow: some View {
        if let viewModel, viewModel.isRunning {
            runningContent(viewModel)
        } else {
            idleContent
        }
    }

    func coverage(_ viewModel: AudioAnalysisViewModel) -> LocalizedStringResource {
        guard viewModel.analyzableTrackCount > 0 else {
            return PreferencesStrings.intelligenceAnalysisEmpty
        }
        return PreferencesStrings.intelligenceAnalysisCoverage(
            percent: viewModel.analyzedFraction.formatted(.percent.precision(.fractionLength(0))),
            analyzed: viewModel.analyzedTrackCount,
            total: viewModel.analyzableTrackCount
        )
    }
}

// MARK: - Running

private extension AudioAnalysisSettingsSection {
    func runningContent(_ viewModel: AudioAnalysisViewModel) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            progressHeader(viewModel)
            ProgressView(value: viewModel.progressFraction)
                .tint(tokens.colors.accent.resolve(scheme))
            currentTrackLabel(viewModel)
            runningControls(viewModel)
        }
        .padding(.vertical, tokens.spacing.xxSmall)
    }

    func progressHeader(_ viewModel: AudioAnalysisViewModel) -> some View {
        HStack(spacing: tokens.spacing.small) {
            Text(
                viewModel.isPaused
                    ? PreferencesStrings.intelligenceAnalysisPaused
                    : PreferencesStrings.intelligenceAnalysisRunning
            )
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
    func currentTrackLabel(_ viewModel: AudioAnalysisViewModel) -> some View {
        if let track = viewModel.currentTrack {
            Text(verbatim: track)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func runningControls(_ viewModel: AudioAnalysisViewModel) -> some View {
        HStack(spacing: tokens.spacing.small) {
            pauseResumeButton(viewModel)
            Button(role: .destructive) {
                viewModel.stop()
            } label: {
                Label { Text(EnrichmentStrings.stop) } icon: { Image(systemName: "stop.fill") }
            }
            .accessibilityIdentifier("intelligence.analysisStop")
            Spacer()
        }
        .padding(.top, tokens.spacing.xxSmall)
    }

    @ViewBuilder
    func pauseResumeButton(_ viewModel: AudioAnalysisViewModel) -> some View {
        if viewModel.isPaused {
            Button {
                viewModel.resume()
            } label: {
                Label { Text(EnrichmentStrings.resume) } icon: { Image(systemName: "play.fill") }
            }
            .accessibilityIdentifier("intelligence.analysisResume")
        } else {
            Button {
                viewModel.pause()
            } label: {
                Label { Text(EnrichmentStrings.pause) } icon: { Image(systemName: "pause.fill") }
            }
            .accessibilityIdentifier("intelligence.analysisPause")
        }
    }
}

// MARK: - Idle

private extension AudioAnalysisSettingsSection {
    var idleContent: some View {
        HStack(spacing: tokens.spacing.small) {
            Spacer(minLength: 0)
            Button {
                confirmsRescan = true
            } label: {
                Label { Text(PreferencesStrings.intelligenceAnalysisRescan) } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .accessibilityIdentifier("intelligence.analysisRescan")
            .help(PreferencesStrings.intelligenceAnalysisRescanHelp)
            .pointingHandCursor()
            .disabled(viewModel == nil)
            Button {
                viewModel?.start()
            } label: {
                Label { Text(PreferencesStrings.intelligenceAnalysisStart) } icon: {
                    Image(systemName: "waveform")
                }
            }
            .accessibilityIdentifier("intelligence.analysisStart")
            .help(PreferencesStrings.intelligenceAnalysisStartHelp)
            .pointingHandCursor()
            .disabled(viewModel == nil)
        }
        .padding(.vertical, tokens.spacing.xxSmall)
    }
}
