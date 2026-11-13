// ParametricEQNode — the AVFAudio boundary of MacAMP's parametric-EQ mode.
//
// `ParametricFilter` / `ParametricEQConfiguration` are pure data. This file is
// where that data becomes an `AVAudioUnitEQ`: the node factory, the typed error
// for the band-capacity ceiling, and the single routine that programs a
// configuration onto a node's bands.
//
// THE PRE-AMP NEVER LANDS HERE. `ParametricEQConfiguration.preampDB` is a gain
// contribution, not a filter, and it routes through ``GainComposer`` alongside
// ReplayGain, the graphic pre-amp and the head-room trim. Writing it onto this
// node's `globalGain` (or the graphic node's) would silently overwrite every
// other contributor — precisely the bug ``GainComposer`` exists to prevent — so
// ``AVAudioUnitEQ/applyParametricConfiguration(_:)`` pins `globalGain` to 0 on
// every apply rather than leaving it merely un-written.
//
// This file imports only AVFAudio + Foundation; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import AVFAudio
import Foundation

// MARK: - Errors

/// The failures the parametric engine seam
/// (``PlaybackEngine/setParametricConfiguration(_:)``) can report.
///
/// Deliberately separate from ``AutoEqParseError``: a configuration reaches the
/// engine from the parametric editor as readily as from a parsed profile, and an
/// engine refusing a hand-edited filter list must not claim a file failed to
/// parse. Cases carry **data, not prose** — PlayerCore holds no user-facing copy.
public enum ParametricEQConfigurationError: Error, Sendable, Equatable, Hashable {
    /// The configuration carries more filters than the parametric node has bands.
    case tooManyFilters(count: Int, maximum: Int)
}

// MARK: - Node factory

/// Builds the parametric `AVAudioUnitEQ` for the playback graph — one band per
/// ``ParametricEQConfiguration/maximumFilterCount`` slot, every one **bypassed**.
///
/// The band count is fixed at construction because `AVAudioUnitEQ` has no way to
/// resize afterwards, so the node is created at the ceiling and the bands a
/// configuration does not use are bypassed rather than removed. A bypassed band
/// still needs legal parameters (0 Hz is outside the AU's documented
/// `20 Hz … Nyquist` range), so every band is left at a neutral, valid
/// 1 kHz / 0 dB / 0.5-octave peaking shape.
///
/// Sibling of ``makeEQUnit()``, which builds the untouched ten-band graphic unit.
/// The two are independent nodes in different chain slots; nothing here reads or
/// writes the graphic unit's layout.
public func makeParametricEQUnit() -> AVAudioUnitEQ {
    let unit = AVAudioUnitEQ(numberOfBands: ParametricEQConfiguration.maximumFilterCount)
    for parameters in unit.bands {
        parameters.filterType = .parametric
        parameters.frequency = 1000
        parameters.bandwidth = 0.5
        parameters.gain = 0
        parameters.bypass = true
    }
    unit.globalGain = 0
    return unit
}

// MARK: - Capacity

public extension ParametricEQConfiguration {
    /// Refuses a configuration that cannot fit the parametric node's bands.
    ///
    /// Lives on the configuration rather than inside one engine because the
    /// ceiling is a property of the CONTRACT — ``maximumFilterCount`` is the same
    /// number the profile parser and the editor enforce — so every conformer of
    /// ``PlaybackEngine`` refuses an over-capacity profile identically, including
    /// the doubles that own no audio graph at all.
    ///
    /// - Throws: ``ParametricEQConfigurationError/tooManyFilters(count:maximum:)``.
    func validateFilterCapacity() throws {
        let maximum = Self.maximumFilterCount
        guard filters.count <= maximum else {
            throw ParametricEQConfigurationError.tooManyFilters(
                count: filters.count,
                maximum: maximum
            )
        }
    }
}

// MARK: - Programming a node

extension AVAudioUnitEQ {
    /// Programs `configuration`'s filters onto this node's bands, bypassing every
    /// band the configuration does not use.
    ///
    /// Filter `i` is programmed onto band `i`, so the configuration's order is
    /// preserved even though the magnitude response does not depend on it (the
    /// bands are in series). Frequency is clamped up to
    /// ``ParametricEQLimits/minimumFrequency``; gain and bandwidth arrive already
    /// clamped as ``ParametricFilter/auGain`` / ``ParametricFilter/auBandwidth``.
    /// The AU's frequency CEILING is Nyquist — sample-rate dependent, and the
    /// graph's rate changes under us on every format change — so it is left to
    /// the AU, which is the only party that knows the current rate.
    ///
    /// - Important: `configuration.preampDB` is NOT applied. It is a gain
    ///   contribution that routes through ``GainComposer/setParametricPreamp(_:)``;
    ///   `globalGain` is pinned to 0 here so a future edit cannot quietly start
    ///   summing the pre-amp twice.
    ///
    /// The caller is responsible for the capacity check
    /// (``ParametricEQConfiguration/validateFilterCapacity()``): filters beyond
    /// the band count are ignored rather than trapped, because a render graph is
    /// the wrong place to discover a ceiling violation.
    func applyParametricConfiguration(_ configuration: ParametricEQConfiguration) {
        for (index, parameters) in bands.enumerated() {
            guard index < configuration.filters.count else {
                parameters.gain = 0
                parameters.bypass = true
                continue
            }
            let filter = configuration.filters[index]
            parameters.filterType = filter.type.avFilterType
            parameters.frequency = Float(max(filter.frequency, ParametricEQLimits.minimumFrequency))
            parameters.bandwidth = filter.auBandwidth
            parameters.gain = filter.auGain
            parameters.bypass = false
        }
        globalGain = 0
    }
}
