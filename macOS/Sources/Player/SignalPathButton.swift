// SignalPathButton — the player bar's format capsule, promoted to a control.
//
// The capsule already stated the playing file's bitrate and sample rate; the
// signal path is the rest of that same sentence, so the capsule opens it rather
// than the bar growing another glyph. Its compact rendering is UNCHANGED from the
// inline version it replaced in `PlayerBarScrubber` — deliberately terser than
// `SignalPathModel.sourceFormat`, which belongs in the panel where there is room
// for it.
//
// The popover's content is not constructed while it is closed, so the panel costs
// nothing when hidden (see `SignalPathPopover` for the no-timer contract).
import DesignSystem
import Persistence
import SwiftUI

/// The player-bar capsule that presents the signal-path panel.
struct SignalPathButton: View {
    /// The full record for the playing track, which carries the bit depth a
    /// ``TrackRef`` does not.
    var trackRecord: TrackRecord?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var isPresented = false

    var body: some View {
        if let display = capsuleText, !display.isEmpty {
            Button {
                isPresented.toggle()
            } label: {
                capsule(display)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(Text(SignalPathStrings.help))
            .accessibilityLabel(Text(SignalPathStrings.accessibilityLabel))
            .accessibilityHint(Text(SignalPathStrings.accessibilityHint))
            .accessibilityIdentifier("player.signalPathButton")
            .popover(isPresented: $isPresented) {
                SignalPathPopover(trackRecord: trackRecord)
                    .environment(environment)
                    .designTokens(tokens)
            }
        }
    }

    private func capsule(_ display: String) -> some View {
        Text(verbatim: display)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, tokens.spacing.small)
            .padding(.vertical, tokens.spacing.xxSmall)
            .background(
                Capsule(style: .continuous)
                    .fill(tokens.colors.accent.resolve(scheme).opacity(0.12))
            )
    }

    /// Bitrate and sample rate when the tags carry them, else the bare container
    /// extension. `nil` when nothing is playing.
    private var capsuleText: String? {
        guard let track = environment.player.currentTrack else { return nil }
        let bitrate = track.bitrate ?? trackRecord?.bitrate
        let rate = track.sampleRate ?? trackRecord?.sampleRate
        let ext = URL(fileURLWithPath: track.filePath).pathExtension.uppercased()
        let parts = [
            bitrate.map { "\($0 / 1000)kbps" },
            rate.map { Self.sampleRateText($0) },
        ].compactMap(\.self)
        return parts.isEmpty ? ext : parts.joined(separator: " · ")
    }

    private static func sampleRateText(_ hertz: Int) -> String {
        guard hertz >= 1000 else { return "\(hertz)Hz" }
        let khz = Double(hertz) / 1000.0
        return khz.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(khz))kHz"
            : String(format: "%.1fkHz", khz)
    }
}

#Preview("Signal path") {
    SignalPathPopover(trackRecord: nil)
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
}
