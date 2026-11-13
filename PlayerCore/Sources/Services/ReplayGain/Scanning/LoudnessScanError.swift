//
//  LoudnessScanError.swift
//  MacAMP PlayerCore — Services
//
//  Why an offline loudness scan could not produce a measurement.
//
//  Modelled on ``AudioFeatureError``: two cases, both carrying the URL, because
//  the batch service draws exactly one distinction — a track either committed a
//  row or was tallied as a failure. The reason string is for a log line, never
//  for the screen (PlayerCore holds no user-facing copy).
//
//  This file imports only Foundation; it MUST NOT import AppKit or UIKit
//  (PlayerCore portability invariant).
//

import Foundation

/// A typed failure from ``LoudnessScanner``.
public enum LoudnessScanError: Error, Sendable, Equatable {
    /// The decoder opened but its format is unusable (no sample rate, no
    /// channels), or its buffers could not be allocated.
    case unreadableStream(url: URL)

    /// The decoder could not be built, or the decode failed part-way through.
    case decodeFailed(url: URL, reason: String)
}
