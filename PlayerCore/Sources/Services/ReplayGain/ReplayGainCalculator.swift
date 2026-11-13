//
//  ReplayGainCalculator.swift
//  MacAMP PlayerCore — Services
//
//  The pure, deterministic ReplayGain math: (tags + mode + pre-amp) -> applied
//  dB. This is the heavily-tested part — it has no engine, I/O, or audio-thread
//  dependencies, so it can be exercised exhaustively in isolation.
//
//  This file imports only AudioEngine (for the canonical gain clamp), Metadata
//  (the ``ReplayGain`` tag value type) and Foundation (`log10`); it MUST NOT
//  import AppKit or UIKit (PlayerCore portability invariant).
//

import AudioEngine
import Foundation
import Metadata

// MARK: - ReplayGainComputing

/// A pure function turning ReplayGain tags + the user's mode/pre-amp into the
/// gain (dB) that should be applied to playback.
///
/// Conformers are stateless value types so a single instance can serve any
/// number of tracks concurrently (`Sendable`). The result is already anti-clip
/// limited and clamped to the engine's valid range — the caller hands it
/// straight to `PlaybackEngine.setGlobalGain(_:)`.
public protocol ReplayGainComputing: Sendable {
    /// The gain (dB) to apply for `tags` under `mode` with the user `preamp` (dB).
    func appliedGain(for tags: ReplayGain, mode: ReplayGainMode, preamp: Double) -> Double
}

// MARK: - ReplayGainCalculator

/// The default ``ReplayGainComputing``: tag-based gain + pre-amp, an anti-clip
/// limiter against the relevant peak, and a final clamp to the engine's
/// ``globalGainRange`` (−96…+24 dB).
///
/// Anti-clip rule (the ADR invariant): if applying the gain would drive the
/// stored peak above full scale (`peak · 10^(gain/20) > 1`), the gain is reduced
/// so the peak lands at *exactly* full scale — never above. Track mode limits
/// against `TRACK_PEAK`, album mode against `ALBUM_PEAK`.
public struct ReplayGainCalculator: ReplayGainComputing {
    public init() {}

    public func appliedGain(for tags: ReplayGain, mode: ReplayGainMode, preamp: Double) -> Double {
        switch mode {
        case .off:
            // ReplayGain disabled → unity. The pre-amp trims a ReplayGain
            // reference, so it does nothing without one.
            0
        case .track:
            resolve(gain: tags.trackGain, peak: tags.trackPeak, preamp: preamp)
        case .album:
            // Album mode falls back to the track values when the album-coherent
            // tags are absent (a single-track "album" carries only track tags).
            resolve(
                gain: tags.albumGain ?? tags.trackGain,
                peak: tags.albumPeak ?? tags.trackPeak,
                preamp: preamp
            )
        }
    }

    /// Combines a single (gain, peak) pair with the pre-amp, applies anti-clip,
    /// then clamps. `gain == nil` means the file has a peak but no loudness
    /// reference → peak-only fallback (never boost, only attenuate to avoid a
    /// clip), which degrades gracefully to 0 dB.
    private func resolve(gain: Double?, peak: Double?, preamp: Double) -> Double {
        let ceiling = peakCeiling(peak)

        guard let gain else {
            // No loudness reference: apply 0 dB, but still pull a hot file back
            // below full scale if its peak demands it.
            return clamp(min(0, ceiling ?? 0))
        }

        var applied = gain + preamp
        if let ceiling, applied > ceiling {
            applied = ceiling // anti-clip: peak hits exactly full scale, not over
        }
        return clamp(applied)
    }

    /// The largest gain (dB) that keeps `peak` at or below full scale: the `g`
    /// solving `peak · 10^(g/20) = 1`, i.e. `g = −20 · log10(peak)`. Returns
    /// `nil` when there is no usable peak (absent or non-positive), so no
    /// anti-clip limit applies.
    private func peakCeiling(_ peak: Double?) -> Double? {
        guard let peak, peak > 0 else { return nil }
        return -20.0 * log10(peak)
    }

    /// Clamps to the engine's ``globalGainRange`` so the calculator and the
    /// `AVAudioUnitEQ.globalGain` it feeds share one source of truth for the
    /// safe range (−96…+24 dB).
    private func clamp(_ value: Double) -> Double {
        let lower = Double(globalGainRange.lowerBound)
        let upper = Double(globalGainRange.upperBound)
        return min(upper, max(lower, value))
    }
}
