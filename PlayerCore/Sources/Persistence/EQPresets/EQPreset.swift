import Foundation

// EQPreset — a named 10-band graphic-equaliser preset for MacAMP.
//
// The ten bands match the ISO octave layout in AudioEngine's `EQBand`:
// 32 · 64 · 125 · 250 · 500 · 1k · 2k · 4k · 8k · 16k Hz.
// Band gains are in dB; the optional `preamp` is an additional global trim
// applied before the per-band gains (useful for preventing clipping on
// boosted presets).
//
// Built-in presets are code constants (never persisted). Only custom
// user-created presets are stored in the `eqPreset` SQLite table.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).

/// A named 10-band graphic-equaliser preset.
///
/// `bandGains` is always exactly 10 elements, ordered by ascending centre
/// frequency: 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz — matching
/// `EQBand.allCases` order.
public struct EQPreset: Codable, Sendable, Equatable, Hashable {
    /// Display name shown in the UI.
    public var name: String

    /// Per-band gain in dB. Always exactly 10 values (index == `EQBand.rawValue`).
    public var bandGains: [Float]

    /// Optional global pre-amplification trim in dB applied before per-band gains.
    /// Useful for preventing clipping on heavily boosted presets.
    public var preamp: Float?

    /// Creates an EQ preset.
    ///
    /// - Parameters:
    ///   - name: Display name.
    ///   - bandGains: Exactly 10 per-band gains in dB (32 Hz … 16 kHz).
    ///   - preamp: Optional global pre-amp trim in dB.
    public init(name: String, bandGains: [Float], preamp: Float? = nil) {
        precondition(bandGains.count == 10, "EQPreset requires exactly 10 band gains")
        self.name = name
        self.bandGains = bandGains
        self.preamp = preamp
    }
}

// MARK: - Built-in presets

public extension EQPreset {
    /// All built-in presets in display order.
    static let builtIns: [EQPreset] = [
        .flat,
        .rock,
        .pop,
        .jazz,
        .classical,
        .bassBoost,
        .vocal,
        .trebleBoost,
    ]

    // Band order: 32 · 64 · 125 · 250 · 500 · 1k · 2k · 4k · 8k · 16k Hz

    /// Flat — all bands at 0 dB (transparent, no colouration).
    static let flat = EQPreset(
        name: "Flat",
        bandGains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    )

    /// Rock — scooped mids, boosted lows and highs.
    static let rock = EQPreset(
        name: "Rock",
        bandGains: [5, 4, 3, 1, -1, -2, 0, 3, 4, 5],
        preamp: -1
    )

    /// Pop — slight low-mid cut, presence boost.
    static let pop = EQPreset(
        name: "Pop",
        bandGains: [-1, 0, 2, 3, 4, 3, 1, 0, -1, -1]
    )

    /// Jazz — warm low-mids, airy highs.
    static let jazz = EQPreset(
        name: "Jazz",
        bandGains: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]
    )

    /// Classical — gentle low-shelf, open highs, neutral mids.
    static let classical = EQPreset(
        name: "Classical",
        bandGains: [4, 3, 2, 0, -1, -1, 0, 0, 2, 3]
    )

    /// Bass Boost — strong sub and bass emphasis.
    static let bassBoost = EQPreset(
        name: "Bass Boost",
        bandGains: [7, 6, 5, 3, 1, 0, 0, 0, 0, 0],
        preamp: -3
    )

    /// Vocal — presence and clarity for vocals.
    static let vocal = EQPreset(
        name: "Vocal",
        bandGains: [-2, -2, 0, 2, 4, 5, 4, 2, 1, 0]
    )

    /// Treble Boost — air and sparkle in the high frequencies.
    static let trebleBoost = EQPreset(
        name: "Treble Boost",
        bandGains: [0, 0, 0, 0, 0, 1, 2, 4, 6, 7],
        preamp: -2
    )
}

// MARK: - Band-gain helper

public extension EQPreset {
    /// Returns the 10 per-band gain values (dB) in `EQBand.allCases` order.
    ///
    /// This is the array a UI or engine passes directly to `setBandGain(_:dB:)`
    /// for each band index.
    var bandGainValues: [Float] {
        bandGains
    }
}
