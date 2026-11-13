// SignalPathModel — what is actually happening to the audio, as one pure value.
//
// The signal-path panel answers a single question honestly: between the file on
// disk and the output device, what has MacAMP done to the samples? Every input is
// READ from the component that owns it — the composed gain from ``GainComposer``,
// the wired format from `PlaybackEngine.currentConnectionFormat`, the device clock
// from `OutputDeviceControlling.currentNominalRate(for:)` — and nothing here
// re-derives a value a lower layer already publishes.
//
// # Why the badge says "Direct path" and never "bit-perfect"
//
// MacAMP cannot promise bit-perfect output and must not imply it. Two
// `AVAudioMixerNode`s (the balance host and the main mixer) are UNCONDITIONALLY in
// the graph, every sample is converted to 32-bit float on the way through, and the
// system's own output volume sits downstream of the app entirely. "Direct path"
// means only this: MacAMP itself is applying no gain, no equalisation, no
// crossfeed, no pan, and no sample-rate conversion. The panel says the rest out
// loud in its subtitle rather than leaving a listener to infer a guarantee that
// does not exist.
//
// # The six direct-path conditions
//
// 1. ``SignalPathInputs/composedGainDB`` is exactly 0 dB. ONE read covers the
//    ReplayGain trim, the graphic pre-amp, the parametric pre-amp and the head-room
//    trim — the composer is the single source of truth for their sum, so this can
//    never go stale against a summand added later.
// 2. Every graphic EQ band gain is 0 dB.
// 3. No parametric configuration is attached. An attached-but-flat configuration
//    still means the parametric NODE is wired into the chain, which is a processing
//    stage regardless of its coefficients.
// 4. Crossfeed is off.
// 5. Balance is centred (pan == 0).
// 6. The source's sample rate equals the device's nominal rate — the same
//    comparison the SRC indicator makes.
//
// Unknown is never treated as favourable: a missing source rate or device rate
// leaves BOTH ``SignalPathModel/srcActive`` and ``SignalPathModel/directPath``
// false, because neither claim can be substantiated.
//
// This file imports only Foundation + AudioEngine + Services; it MUST NOT import
// AppKit or UIKit (PlayerCore portability invariant), and holds no user-facing
// copy — every value it produces is a non-translatable token (a codec name, a
// number with its unit) that the shell renders with `Text(verbatim:)` beside its
// own localized label.
import AudioEngine
import Foundation
import Services

/// Everything the signal-path readout is derived from, as one value.
///
/// Every field is optional or neutral-by-default so a caller can build it from
/// whatever the current moment actually knows. Absence is rendered as
/// ``SignalPathModel/unknownToken`` and never guessed at.
public struct SignalPathInputs: Sendable, Equatable {
    /// The source container / codec, as a bare token (`"FLAC"`, `"MP3"`, `"DSF"`).
    /// Conventionally the file's uppercased path extension.
    public var codec: String?
    /// The source file's sample rate in Hz.
    public var sourceSampleRate: Int?
    /// The source file's bit depth.
    public var sourceBitDepth: Int?
    /// The source file's nominal bitrate in bits per second.
    public var sourceBitrate: Int?
    /// The clamped sum of every gain MacAMP applies, read from
    /// `GainComposer.composedGainDB`. Never re-derived from its four summands.
    public var composedGainDB: Float
    /// The ReplayGain summand alone, read from `GainComposer.replayGainDB`.
    public var replayGainDB: Float
    /// The ten graphic EQ band gains in dB.
    public var graphicBandGains: [Float]
    /// The attached parametric configuration, or `nil` when no parametric node is
    /// wired into the processing chain.
    public var parametricConfiguration: ParametricEQConfiguration?
    /// Whether the crossfeed stage is engaged.
    public var crossfeedEnabled: Bool
    /// Stereo balance (−1 full-left … 0 centre … +1 full-right).
    public var pan: Float
    /// The sample rate the processing chain is currently wired at.
    public var connectionSampleRate: Double?
    /// The channel count the processing chain is currently wired at.
    public var connectionChannelCount: Int?
    /// The output device's current nominal sample rate.
    public var deviceNominalRate: Double?

    public init(
        codec: String? = nil,
        sourceSampleRate: Int? = nil,
        sourceBitDepth: Int? = nil,
        sourceBitrate: Int? = nil,
        composedGainDB: Float = 0,
        replayGainDB: Float = 0,
        graphicBandGains: [Float] = [],
        parametricConfiguration: ParametricEQConfiguration? = nil,
        crossfeedEnabled: Bool = false,
        pan: Float = 0,
        connectionSampleRate: Double? = nil,
        connectionChannelCount: Int? = nil,
        deviceNominalRate: Double? = nil
    ) {
        self.codec = codec
        self.sourceSampleRate = sourceSampleRate
        self.sourceBitDepth = sourceBitDepth
        self.sourceBitrate = sourceBitrate
        self.composedGainDB = composedGainDB
        self.replayGainDB = replayGainDB
        self.graphicBandGains = graphicBandGains
        self.parametricConfiguration = parametricConfiguration
        self.crossfeedEnabled = crossfeedEnabled
        self.pan = pan
        self.connectionSampleRate = connectionSampleRate
        self.connectionChannelCount = connectionChannelCount
        self.deviceNominalRate = deviceNominalRate
    }
}

/// A pure projection of ``SignalPathInputs`` onto the readout the panel draws.
///
/// Holds no state beyond its inputs, so it is `Equatable` by construction and a
/// view can rebuild it every render without allocating anything durable.
public struct SignalPathModel: Sendable, Equatable {
    /// Rendered in place of any value the current moment does not know.
    public static let unknownToken = "—"

    /// Container tokens that identify Direct Stream Digital source material.
    ///
    /// Recognised by CODEC token rather than by a decoder flag so the badge works
    /// before the DSD playback path lands, and keeps working after it: a `.dsf`
    /// file is DSD whatever the engine chose to do with it.
    public static let dsdCodecs: Set<String> = ["DSD", "DSF", "DFF", "DSDIFF"]

    /// The values this readout was derived from.
    public let inputs: SignalPathInputs

    public init(_ inputs: SignalPathInputs) {
        self.inputs = inputs
    }
}

// MARK: - Processing flags

public extension SignalPathModel {
    /// Whether the source is Direct Stream Digital material.
    var isDSD: Bool {
        guard let codec = inputs.codec?.uppercased(), !codec.isEmpty else { return false }
        return Self.dsdCodecs.contains(codec)
    }

    /// Whether any graphic EQ band is away from 0 dB.
    ///
    /// Bands only — the graphic pre-amp is a gain contribution and is reported by
    /// ``composedGainText`` instead, so neither figure is counted twice.
    var graphicEQActive: Bool {
        inputs.graphicBandGains.contains { $0 != 0 }
    }

    /// Whether a parametric node is wired into the processing chain.
    ///
    /// True for an attached-but-flat configuration: the node is a stage in the
    /// graph whatever its coefficients say.
    var parametricEQActive: Bool {
        inputs.parametricConfiguration != nil
    }

    /// Whether the crossfeed stage is engaged.
    var crossfeedActive: Bool {
        inputs.crossfeedEnabled
    }

    /// Whether MacAMP is applying any gain at all.
    var gainActive: Bool {
        inputs.composedGainDB != 0
    }

    /// Whether the stereo image is being panned.
    var balanceActive: Bool {
        inputs.pan != 0
    }
}

// MARK: - Rate conversion

public extension SignalPathModel {
    /// Whether the source rate and the device's nominal rate disagree — i.e. some
    /// stage between them is resampling.
    ///
    /// False when either rate is unknown: an unsubstantiated claim in either
    /// direction would be worse than saying nothing.
    var srcActive: Bool {
        guard let source = inputs.sourceSampleRate, source > 0,
              let device = inputs.deviceNominalRate, device > 0
        else { return false }
        return !OutputDeviceRateChange.matches(Double(source), device)
    }

    /// Whether the source rate is KNOWN to equal the device's nominal rate.
    ///
    /// Deliberately NOT `!srcActive`: both are false while either rate is unknown,
    /// which is what keeps "unknown" from satisfying the direct-path gate.
    var sourceRateMatchesDevice: Bool {
        guard let source = inputs.sourceSampleRate, source > 0,
              let device = inputs.deviceNominalRate, device > 0
        else { return false }
        return OutputDeviceRateChange.matches(Double(source), device)
    }
}

// MARK: - Direct path

public extension SignalPathModel {
    /// Whether MacAMP is passing the decoded samples through untouched.
    ///
    /// All six conditions in this file's header must hold. This is NOT a
    /// bit-perfect claim — see ``SignalPathModel`` and the panel's own subtitle for
    /// what remains outside the app's control.
    var directPath: Bool {
        !gainActive
            && !graphicEQActive
            && !parametricEQActive
            && !crossfeedActive
            && !balanceActive
            && sourceRateMatchesDevice
    }
}
