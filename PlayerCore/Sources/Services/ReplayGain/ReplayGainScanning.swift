//
//  ReplayGainScanning.swift
//  MacAMP PlayerCore — Services
//
//  The seam for loudness scanning of files that carry no REPLAYGAIN_* tags.
//
//  The default playback path normalizes from the tags the Metadata module reads,
//  with a peak-only anti-clip fallback when a file carries a peak but no gain
//  (see ``ReplayGainCalculator``). Files with NO ReplayGain tags fall back to
//  0 dB unless something scans them.
//
//  ``LoudnessScanner`` (Scanning/) is the shipped conformer: an EBU R128 /
//  BS.1770-4 integrated-loudness + true-peak pass that synthesizes a
//  ``ReplayGain`` from what it measures, which then flows through the exact same
//  ``ReplayGainCalculator`` path — so a scanned file and a tagged one are
//  indistinguishable downstream.
//
//  This file imports only Metadata + Foundation; it MUST NOT import AppKit or
//  UIKit (PlayerCore portability invariant).
//

import Foundation
import Metadata

/// A loudness analyzer that derives ``ReplayGain`` values for a file that has no
/// ReplayGain tags (EBU R128 / BS.1770).
///
/// The production conformer is ``LoudnessScanner``. The default playback path
/// stays tag-based (``ReplayGainCalculator``) with a peak-only anti-clip
/// fallback; a scan result feeds that same calculator, so the rest of the
/// pipeline needs no change.
public protocol ReplayGainScanning: Sendable {
    /// Analyzes `url` and returns synthesized ReplayGain values (gain dB + linear
    /// peak), or throws if the file cannot be decoded for analysis.
    func scan(url: URL) async throws -> ReplayGain
}
