// EQBand — the ten-band graphic-equaliser layout for MacAMP's playback graph.
//
// The audio graph (Option A, per Spikes/ADR-audio-engine.md) inserts a single
// `AVAudioUnitEQ` between the SFBAudioPlayer source node and the main mixer. This
// file owns the fixed ISO band layout and the two pure helpers the engine needs:
// `makeEQUnit()` (construct + configure the unit) and `clampGlobalGain(_:)` (the
// ReplayGain safety clamp). Keeping them here keeps the engine file focused on
// transport/graph wiring and lets the EQ tests exercise the layout in isolation.
//
// This file imports only AVFAudio + Foundation; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import AVFAudio
import Foundation

/// One of the ten ISO-standard octave bands of the graphic equaliser.
///
/// The centre frequencies are the classic ten-band layout
/// `32 · 64 · 125 · 250 · 500 · 1 k · 2 k · 4 k · 8 k · 16 k` Hz. The lowest band
/// is a low shelf, the highest a high shelf, and the eight in between are
/// parametric peaking filters — the standard musical tone-control shape. The
/// `rawValue` is the band's index into `AVAudioUnitEQ.bands`.
public enum EQBand: Int, CaseIterable, Sendable {
    case hz32, hz64, hz125, hz250, hz500
    case hz1k, hz2k, hz4k, hz8k, hz16k

    /// Centre frequency in Hz.
    public var centerFrequency: Float {
        switch self {
        case .hz32: 32
        case .hz64: 64
        case .hz125: 125
        case .hz250: 250
        case .hz500: 500
        case .hz1k: 1000
        case .hz2k: 2000
        case .hz4k: 4000
        case .hz8k: 8000
        case .hz16k: 16000
        }
    }

    /// The filter shape: a low shelf for the lowest band, a high shelf for the
    /// highest, and parametric peaking for the eight interior bands.
    public var filterType: AVAudioUnitEQFilterType {
        switch self {
        case .hz32: .lowShelf
        case .hz16k: .highShelf
        default: .parametric
        }
    }
}

/// The inclusive range (dB) that the EQ's global gain — the ReplayGain trim — is
/// clamped to. Wide enough for any sane ReplayGain value yet bounded so a bogus
/// tag can never drive the output stage to an extreme. Matches the valid range
/// of `AVAudioUnitEQ.globalGain`.
public let globalGainRange: ClosedRange<Float> = -96 ... 24

/// Clamps a global-gain value (dB) into ``globalGainRange`` (−96 … +24 dB).
///
/// Applied to every ReplayGain value before it reaches `AVAudioUnitEQ.globalGain`
/// so an out-of-range tag can never over-boost or over-attenuate the output.
public func clampGlobalGain(_ decibels: Float) -> Float {
    min(max(decibels, globalGainRange.lowerBound), globalGainRange.upperBound)
}

/// Builds a fully configured ten-band `AVAudioUnitEQ` for the playback graph.
///
/// Every band is active (not bypassed) at 0 dB gain — a flat, transparent
/// starting point. Callers adjust individual bands through `bands[i].gain` and
/// the overall ReplayGain trim through `globalGain`.
public func makeEQUnit() -> AVAudioUnitEQ {
    let unit = AVAudioUnitEQ(numberOfBands: EQBand.allCases.count)
    for band in EQBand.allCases {
        let parameters = unit.bands[band.rawValue]
        parameters.filterType = band.filterType
        parameters.frequency = band.centerFrequency
        parameters.bandwidth = 0.5
        parameters.gain = 0
        parameters.bypass = false
    }
    unit.globalGain = 0
    return unit
}
