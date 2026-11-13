// EnrichmentSettingsSection — the metadata-enrichment controls in the Library pane.
//
// One grouped-`Form` section that (1) toggles `AppSettings.autoEnrichOnImport`,
// (2) while a pass runs, shows a token-tinted `ProgressView`, the live counter, the
// current track and Pause/Resume + Stop controls, and (3) while idle, reports the
// last pass — or, when no pass has run, the library's MEASURED coverage — beside an
// "Enrich Now" action.
//
// Control flows through the observable `EnrichmentViewModel` (its purpose) while the
// completed/total counters read the plain `@MainActor EnrichmentService.progress`
// tuple — the read stays reactive because the surrounding rows observe the view
// model's `progressFraction` / `isRunning`, which mutate in the same main-actor step
// as `progress`. Every color, gap and font resolves through the shared
// `DesignTokens`; track names are non-translatable and rendered with `Text(verbatim:)`.
import DesignSystem
import Services
import SwiftUI
import ViewModels

/// The auto-enrich toggle plus live enrichment progress + controls.
struct EnrichmentSettingsSection: View {
    @Binding var autoEnrich: Bool

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Section {
            sectionTitle
            Toggle(isOn: $autoEnrich) {
                Text(EnrichmentStrings.autoEnrichToggle)
            }
            PreferenceCaption(text: EnrichmentStrings.autoEnrichCaption)
            statusRow
                .task { await viewModel.refreshCoverage() }
        }
    }
}

extension EnrichmentSettingsSection {
    /// The one place the view model's idle decision becomes copy.
    ///
    /// The probed variant is chosen only when a lyrics lookup genuinely came back
    /// empty for something, so a library nobody has searched yet never carries a
    /// zeroed "no lyrics found" clause.
    static func resource(for summary: EnrichmentViewModel.IdleSummary) -> LocalizedStringResource {
        switch summary {
        case let .enriched(count):
            EnrichmentStrings.enrichedSummary(count: count)
        case let .coverage(counts) where counts.tracksProbedNoLyrics > 0:
            EnrichmentStrings.coverageSummaryProbed(
                withLyrics: counts.tracksWithLyrics,
                presentTracks: counts.presentTracks,
                noLyricsFound: counts.tracksProbedNoLyrics,
                missingDetails: counts.tracksMissingCoreMetadata
            )
        case let .coverage(counts):
            EnrichmentStrings.coverageSummary(
                withLyrics: counts.tracksWithLyrics,
                presentTracks: counts.presentTracks,
                missingDetails: counts.tracksMissingCoreMetadata
            )
        case .upToDate:
            EnrichmentStrings.upToDate
        }
    }
}

// MARK: - State surfaces

private extension EnrichmentSettingsSection {
    var viewModel: EnrichmentViewModel {
        environment.enrichmentViewModel
    }

    var service: EnrichmentService {
        environment.enrichment
    }

    var sectionTitle: some View {
        Text(EnrichmentStrings.sectionTitle)
            .font(tokens.typography.headline.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
    }

    @ViewBuilder
    var statusRow: some View {
        if viewModel.isRunning {
            runningContent
        } else {
            idleContent
        }
    }
}

// MARK: - Running

private extension EnrichmentSettingsSection {
    var runningContent: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            progressHeader
            ProgressView(value: viewModel.progressFraction)
                .tint(tokens.colors.accent.resolve(scheme))
            currentTrackLabel
            runningControls
        }
        .padding(.vertical, tokens.spacing.xxSmall)
    }

    var progressHeader: some View {
        HStack(spacing: tokens.spacing.small) {
            Text(viewModel.isPaused ? EnrichmentStrings.paused : EnrichmentStrings.enrichingTitle)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Spacer(minLength: tokens.spacing.small)
            Text(EnrichmentStrings.count(completed: service.progress.completed, total: service.progress.total))
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
        } else {
            Button {
                viewModel.pause()
            } label: {
                Label { Text(EnrichmentStrings.pause) } icon: { Image(systemName: "pause.fill") }
            }
        }
    }
}

// MARK: - Idle

private extension EnrichmentSettingsSection {
    var idleContent: some View {
        HStack(spacing: tokens.spacing.small) {
            Text(idleSummary)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            Spacer(minLength: tokens.spacing.small)
            Button {
                viewModel.start()
            } label: {
                Label { Text(EnrichmentStrings.enrichNow) } icon: { Image(systemName: "sparkles") }
            }
        }
        .padding(.vertical, tokens.spacing.xxSmall)
    }

    /// Cheap and synchronous — it reads only already-published view-model state.
    /// The coverage counts behind it are loaded by ``EnrichmentViewModel/refreshCoverage()``,
    /// never by this property.
    var idleSummary: LocalizedStringResource {
        Self.resource(for: viewModel.idleSummary(completed: service.progress.completed))
    }
}
