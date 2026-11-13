// SignalPathPopover — the player-bar readout of what MacAMP is doing to the audio.
//
// A thin view over `SignalPathModel`: every decision (which stages are engaged,
// whether the chain is direct, whether anything is resampling) is made by that pure
// mapper in PlayerCore, and this file only draws the result. Values are
// `Text(verbatim:)` tokens from the mapper; labels come from `SignalPathStrings`.
//
// # No timer, ever
//
// The panel reads live state when it appears and then sits still. The only
// asynchronous work is ONE device-clock read, driven by `.task` — which runs when
// the popover's content is built and is cancelled when it goes away. SwiftUI does
// not construct `.popover` content while the popover is closed, so a hidden panel
// costs exactly nothing and the idle-CPU budget is unaffected. Do NOT add
// `onActiveTick` or a `TimelineView` here.
//
// # What is not wired yet
//
// The parametric-EQ stage (plan todo 19) has no engine accessor at the time of
// writing, so its input is reported as absent. When that todo lands, feed the real
// value in `makeInputs()` — the mapper and this view already account for it. The
// crossfeed stage IS wired: `makeInputs()` reads node presence off the engine.
import AudioEngine
import AVFAudio
import CoreAudio
import DesignSystem
import Models
import Persistence
import Services
import SwiftUI
import ViewModels

/// The signal-path panel presented from the player bar's format capsule.
struct SignalPathPopover: View {
    /// The full record for the playing track, which carries the bit depth a
    /// ``TrackRef`` does not.
    var trackRecord: TrackRecord?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var deviceNominalRate: Double?

    var body: some View {
        let model = SignalPathModel(makeInputs())
        VStack(alignment: .leading, spacing: tokens.spacing.medium) {
            header(model)
            sourceSection(model)
            processingSection(model)
            outputSection(model)
            verdict(model)
        }
        .padding(tokens.spacing.medium)
        .frame(width: 340)
        .task { await loadDeviceRate() }
    }
}

// MARK: - Sections

private extension SignalPathPopover {
    func header(_ model: SignalPathModel) -> some View {
        HStack(spacing: tokens.spacing.xSmall) {
            Text(SignalPathStrings.title)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Spacer(minLength: 0)
            if model.isDSD {
                badge(SignalPathStrings.dsdBadge, tint: tokens.colors.accent.resolve(scheme))
                    .accessibilityIdentifier("signalPath.dsdBadge")
            }
        }
    }

    func sourceSection(_ model: SignalPathModel) -> some View {
        section(SignalPathStrings.sectionSource) {
            row(SignalPathStrings.fieldFormat, model.sourceFormat, identifier: "signalPath.sourceFormat")
            if environment.player.currentTrack == nil {
                caption(SignalPathStrings.stateNotPlaying)
            }
        }
    }

    func processingSection(_ model: SignalPathModel) -> some View {
        section(SignalPathStrings.sectionProcessing) {
            row(SignalPathStrings.fieldReplayGain, model.replayGainText)
            row(SignalPathStrings.fieldTotalGain, model.composedGainText, isActive: model.gainActive)
            stateRow(
                SignalPathStrings.fieldGraphicEQ,
                isActive: model.graphicEQActive,
                inactive: SignalPathStrings.stateFlat
            )
            stateRow(SignalPathStrings.fieldParametricEQ, isActive: model.parametricEQActive)
            stateRow(SignalPathStrings.fieldCrossfeed, isActive: model.crossfeedActive)
            if model.balanceActive {
                row(SignalPathStrings.fieldBalance, model.balanceText, isActive: true)
            } else {
                labelledRow(SignalPathStrings.fieldBalance, SignalPathStrings.stateCentre, isActive: false)
            }
        }
    }

    func outputSection(_ model: SignalPathModel) -> some View {
        section(SignalPathStrings.sectionOutput) {
            row(SignalPathStrings.fieldEngineFormat, model.connectionFormat)
            row(SignalPathStrings.fieldDeviceRate, model.deviceRateText)
            labelledRow(
                SignalPathStrings.srcBadge,
                model.srcActive ? SignalPathStrings.stateOn : SignalPathStrings.stateOff,
                isActive: model.srcActive,
                activeTint: tokens.colors.warning.resolve(scheme),
                identifier: "signalPath.srcIndicator"
            )
            if model.srcActive {
                caption(SignalPathStrings.srcSubtitle)
            }
        }
    }

    /// The badge, and the sentence that keeps it honest. Both are always present —
    /// a direct path and a processed path are two answers to one question, not a
    /// present/absent decoration.
    func verdict(_ model: SignalPathModel) -> some View {
        let tint = model.directPath
            ? tokens.colors.success.resolve(scheme)
            : tokens.colors.textSecondary.resolve(scheme)
        return VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            Divider()
            HStack(spacing: tokens.spacing.xSmall) {
                Image(systemName: model.directPath ? "checkmark.seal.fill" : "waveform.path")
                    .foregroundStyle(tint)
                Text(model.directPath ? SignalPathStrings.directPathTitle : SignalPathStrings.processedTitle)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(tint)
                    // On the TEXT, not the enclosing stack: a container exposes an
                    // empty label, so an assertion on the badge would read nothing.
                    .accessibilityIdentifier("signalPath.verdict")
            }
            .padding(.top, tokens.spacing.xxSmall)
            caption(model.directPath ? SignalPathStrings.directPathSubtitle : SignalPathStrings.processedSubtitle)
        }
    }
}

// MARK: - Building blocks

private extension SignalPathPopover {
    func section(_ header: LocalizedStringResource, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            Text(header)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .textCase(.uppercase)
            rows()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A label / verbatim-token pair. `value` is DATA from ``SignalPathModel`` —
    /// never translatable copy.
    ///
    /// `identifier` lands on the VALUE text, not on the row, so an assertion reads
    /// the mapped token exactly rather than a container's combined label.
    func row(
        _ label: LocalizedStringResource,
        _ value: String,
        isActive: Bool = false,
        identifier: String? = nil
    ) -> some View {
        rowLayout(label) {
            Text(verbatim: value)
                .font(tokens.typography.body.font.monospacedDigit())
                .foregroundStyle(valueTint(isActive: isActive))
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier ?? "")
        }
    }

    /// A label / localized-state pair, for rows whose value is a word rather than a
    /// measurement.
    func labelledRow(
        _ label: LocalizedStringResource,
        _ value: LocalizedStringResource,
        isActive: Bool,
        activeTint: Color? = nil,
        identifier: String? = nil
    ) -> some View {
        rowLayout(label) {
            Text(value)
                .font(tokens.typography.body.font)
                .foregroundStyle(activeTint.map { isActive ? $0 : valueTint(isActive: false) }
                    ?? valueTint(isActive: isActive))
                .accessibilityIdentifier(identifier ?? "")
        }
    }

    func stateRow(
        _ label: LocalizedStringResource,
        isActive: Bool,
        inactive: LocalizedStringResource = SignalPathStrings.stateOff
    ) -> some View {
        labelledRow(label, isActive ? SignalPathStrings.stateOn : inactive, isActive: isActive)
    }

    func rowLayout(_ label: LocalizedStringResource, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.small) {
            Text(label)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .frame(width: 104, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func caption(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func badge(_ text: LocalizedStringResource, tint: Color) -> some View {
        Text(text)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tint)
            .padding(.horizontal, tokens.spacing.xSmall)
            .padding(.vertical, tokens.spacing.hairline * 2)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
    }

    /// An engaged stage is drawn in the accent so the panel can be read at a glance;
    /// a neutral one stays in the primary text colour rather than being greyed out,
    /// because "0.0 dB" is a measurement, not a disabled control.
    func valueTint(isActive: Bool) -> Color {
        isActive
            ? tokens.colors.accent.resolve(scheme)
            : tokens.colors.textPrimary.resolve(scheme)
    }
}

// MARK: - Inputs

private extension SignalPathPopover {
    /// Reads each value from the component that OWNS it. In particular the gain
    /// figures come from `GainComposer` — the composed total is read, never
    /// re-summed from its four contributors.
    func makeInputs() -> SignalPathInputs {
        let track = environment.player.currentTrack
        let composer = environment.engine.gainComposer
        let connection = environment.engine.currentConnectionFormat
        return SignalPathInputs(
            codec: track.map { URL(fileURLWithPath: $0.filePath).pathExtension },
            sourceSampleRate: track?.sampleRate ?? trackRecord?.sampleRate,
            sourceBitDepth: trackRecord?.bitDepth,
            sourceBitrate: track?.bitrate ?? trackRecord?.bitrate,
            composedGainDB: composer.composedGainDB,
            replayGainDB: composer.replayGainDB,
            graphicBandGains: environment.equalizer.bandGains,
            // Wired by plan todo 19 (parametric).
            parametricConfiguration: nil,
            // The STAGE, not the preference: `crossfeedLevel` is `nil` whenever the node
            // is not in the chain, so a switch that is on while the unit failed to
            // install reads here as off — which is what the signal path actually is.
            crossfeedEnabled: environment.engine.crossfeedLevel != nil,
            pan: environment.player.balance,
            connectionSampleRate: connection.sampleRate,
            connectionChannelCount: Int(connection.channelCount),
            deviceNominalRate: deviceNominalRate
        )
    }

    /// One HAL read, off the main actor, only while the panel is on screen.
    ///
    /// `CoreAudioNominalRate.current` is a synchronous C call that can block for
    /// milliseconds, so it is never run on the main actor. A device that refuses
    /// the property leaves the rate `nil`, which the mapper renders as unknown and
    /// treats as "cannot claim a direct path" — never as a match.
    func loadDeviceRate() async {
        guard let deviceID = environment.engine.outputDeviceID else {
            deviceNominalRate = nil
            return
        }
        let object = AudioObjectID(deviceID)
        deviceNominalRate = await Task.detached { try? CoreAudioNominalRate.current(of: object) }.value
    }
}
