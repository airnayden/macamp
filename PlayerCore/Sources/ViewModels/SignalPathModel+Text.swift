// SignalPathModel+Text — the non-translatable display tokens of the signal path.
//
// Every string produced here is DATA, not copy: a codec name, a number with its
// unit, a channel count. The shell renders them with `Text(verbatim:)` beside its
// own String Catalog label, exactly as `TagsPanelView` does for tag values, so
// nothing in PlayerCore holds user-facing prose.
//
// Numbers go through `String(format:)`, which is locale-independent — the same
// choice `TagsPanelView` and `PlayerBarScrubber` already make for "kHz" / "kbps"
// readouts, and the one that keeps these tokens assertable in tests.
import Foundation

public extension SignalPathModel {
    /// The source line: codec, sample rate, bit depth and bitrate, in that order,
    /// joined by a middot — with every unknown component OMITTED rather than
    /// padded, so a sparsely-tagged file reads as what is known about it.
    ///
    /// ``SignalPathModel/unknownToken`` when nothing at all is known.
    var sourceFormat: String {
        let parts = [codecToken, sourceSampleRateToken, sourceBitDepthToken, sourceBitrateToken]
            .filter { $0 != Self.unknownToken }
        return parts.isEmpty ? Self.unknownToken : parts.joined(separator: " · ")
    }

    /// The source container / codec token, uppercased.
    var codecToken: String {
        guard let codec = inputs.codec?.trimmingCharacters(in: .whitespaces), !codec.isEmpty else {
            return Self.unknownToken
        }
        return codec.uppercased()
    }

    /// The source file's sample rate, e.g. `"44.1 kHz"`.
    var sourceSampleRateToken: String {
        guard let rate = inputs.sourceSampleRate, rate > 0 else { return Self.unknownToken }
        return SignalPathTokens.kilohertz(Double(rate))
    }

    /// The source file's bit depth, e.g. `"16-bit"`.
    var sourceBitDepthToken: String {
        guard let depth = inputs.sourceBitDepth, depth > 0 else { return Self.unknownToken }
        return "\(depth)-bit"
    }

    /// The source file's nominal bitrate, e.g. `"1411 kbps"`.
    var sourceBitrateToken: String {
        guard let bitrate = inputs.sourceBitrate, bitrate > 0 else { return Self.unknownToken }
        return "\(bitrate / 1000) kbps"
    }

    /// The ReplayGain summand alone, e.g. `"-4.0 dB"`.
    var replayGainText: String {
        SignalPathTokens.decibels(inputs.replayGainDB)
    }

    /// Every gain MacAMP applies, summed and clamped, e.g. `"-10.0 dB"`.
    var composedGainText: String {
        SignalPathTokens.decibels(inputs.composedGainDB)
    }

    /// The stereo balance as a signed fraction, e.g. `"0.00"` or `"+0.30"`.
    var balanceText: String {
        inputs.pan == 0 ? "0.00" : String(format: "%+.2f", inputs.pan)
    }

    /// The format the processing chain is wired at, e.g. `"44.1 kHz · 2 ch"`.
    var connectionFormat: String {
        let parts = [connectionSampleRateToken, connectionChannelToken]
            .filter { $0 != Self.unknownToken }
        return parts.isEmpty ? Self.unknownToken : parts.joined(separator: " · ")
    }

    /// The sample rate the processing chain is wired at.
    var connectionSampleRateToken: String {
        guard let rate = inputs.connectionSampleRate, rate > 0 else { return Self.unknownToken }
        return SignalPathTokens.kilohertz(rate)
    }

    /// The channel count the processing chain is wired at, e.g. `"2 ch"`.
    var connectionChannelToken: String {
        guard let channels = inputs.connectionChannelCount, channels > 0 else { return Self.unknownToken }
        return "\(channels) ch"
    }

    /// The output device's current nominal rate.
    var deviceRateText: String {
        guard let rate = inputs.deviceNominalRate, rate > 0 else { return Self.unknownToken }
        return SignalPathTokens.kilohertz(rate)
    }
}

/// Number-to-token formatting for the signal-path readout.
///
/// Internal: these are the panel's own spelling rules, not a general utility.
enum SignalPathTokens {
    /// Hertz as kilohertz, dropping a trailing `.0` so 48 kHz does not read
    /// `"48.0 kHz"` next to `"44.1 kHz"`.
    static func kilohertz(_ hertz: Double) -> String {
        let kilo = hertz / 1000
        return kilo == kilo.rounded()
            ? "\(Int(kilo.rounded())) kHz"
            : String(format: "%.1f kHz", kilo)
    }

    /// Decibels to one decimal place, signed — except at unity, which reads
    /// `"0.0 dB"` rather than `"+0.0 dB"`.
    static func decibels(_ value: Float) -> String {
        value == 0 ? "0.0 dB" : String(format: "%+.1f dB", value)
    }
}
