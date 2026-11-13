//
//  FLACIntegrityResult.swift
//  MacAMP PlayerCore — Services
//
//  The verdict of a FLAC stream MD5 verification, and the ways it can fail.
//
//  PlayerCore portability: Foundation only.
//

import Foundation

// MARK: - FLACIntegrityResult

/// What a full decode of a FLAC stream proved about its stored checksum.
///
/// Every case is a real ANSWER — a file that decodes end to end always yields
/// one of the three. Conditions that prevent an answer (not a FLAC stream, an
/// unusable format, a decode failure) are thrown as ``FLACIntegrityError``
/// instead, so a caller can never mistake "could not check" for "checked, and
/// it is fine".
public enum FLACIntegrityResult: Sendable, Equatable {
    /// STREAMINFO carries a checksum and the decoded samples reproduce it
    /// exactly. The file is bit-identical to what was encoded.
    case match

    /// STREAMINFO carries a checksum the decoded samples do **not** reproduce.
    ///
    /// Either the audio data or the stored checksum has changed since the file
    /// was written. Both values are carried so a report can show them.
    case mismatch(stored: Data, computed: Data)

    /// STREAMINFO's checksum field is the all-zero sentinel, whose defined
    /// meaning is "no MD5 was recorded" — there is nothing to verify against.
    ///
    /// The stream is still decoded in full (the reference `flac -t` does the
    /// same, because the frame CRCs are checked on the way through), so the
    /// computed digest is reported for a caller that wants to record it.
    case noStoredMD5(computed: Data)

    /// `true` only for ``match`` — never for a stream that had nothing to
    /// check against.
    public var isMatch: Bool {
        self == .match
    }
}

// MARK: - FLACIntegrityError

/// A condition that prevented a verdict from being reached.
public enum FLACIntegrityError: Error, Equatable, Sendable {
    /// The decoder opened the file but it publishes no FLAC STREAMINFO
    /// checksum — i.e. it is not a FLAC stream.
    case notFLAC(url: URL)

    /// The stream opened but its PCM layout cannot be reduced to FLAC's
    /// canonical sample bytes (non-native endianness, floating point, or a
    /// container width this verifier does not model).
    case unsupportedLayout(url: URL)

    /// The decoder failed part-way through the stream.
    case decodeFailed(url: URL, reason: String)

    /// The decoder could not be opened at all.
    case unreadable(url: URL, reason: String)
}
