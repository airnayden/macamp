//
//  ReplayGainMode.swift
//  MacAMP PlayerCore — Services
//
//  The user-selectable ReplayGain reference. Pure value type (no imports); the
//  loudness math lives in ``ReplayGainCalculator`` and the engine wiring in
//  ``ReplayGainService``.
//

/// Which ReplayGain reference MacAMP honors when computing playback gain.
///
/// - ``off``: ReplayGain disabled — the engine runs at unity (0 dB), even when
///   the user has dialed in a pre-amp (the pre-amp only trims a *ReplayGain*
///   reference, so it is meaningless without one).
/// - ``track``: normalize each track to its own ``ReplayGain/trackGain`` /
///   ``ReplayGain/trackPeak`` — every song plays at a consistent loudness.
/// - ``album``: normalize to ``ReplayGain/albumGain`` / ``ReplayGain/albumPeak``
///   so an album's intended quiet/loud dynamics across tracks are preserved.
public enum ReplayGainMode: String, Sendable, CaseIterable, Codable {
    case off
    case track
    case album
}
