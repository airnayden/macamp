// DecodingError — the typed error model for MacAMP's decode layer.
//
// Every failure path in the Decoding module surfaces as a `DecodingError`.
// Corrupt, truncated, unsupported and unreadable inputs are ALWAYS mapped to
// one of these cases — the module never force-unwraps, never traps, and never
// lets a raw SFBAudioEngine / Foundation `NSError` escape to callers. The audio
// engine (Task 9) pattern-matches these cases to drive its error UI.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// A typed, `Sendable` description of why a decode could not proceed.
///
/// The five cases form a deliberate triage ladder from "we can't even read the
/// bytes" up to "the bytes are there but the container/codec is unknown":
///
/// - ``ioError(url:underlying:)`` — the file could not be read at all (missing,
///   permissions, a device error). The underlying message is preserved verbatim.
/// - ``unsupportedFormat(url:)`` — the bytes were read but no registered decoder
///   recognises the container/codec (wrong extension, an exotic format, …).
/// - ``corruptedFile(url:reason:)`` — a decoder *did* claim the file but its
///   contents are malformed (bad frames, failed CRC, garbage payload).
/// - ``truncated(url:)`` — the stream ends earlier than its header promised.
/// - ``unsupportedSampleRate(url:detail:)`` — the container and codec ARE
///   recognised, but the stream's sample rate is one this build refuses to
///   convert. Today the only producer is DSD: MacAMP plays DSD64 as decimated
///   PCM and REFUSES DSD128/256/512 rather than resampling them.
///
/// `unsupportedSampleRate` is deliberately distinct from `unsupportedFormat`:
/// "we know this format, just not at this rate" is a different thing to tell a
/// user than "we don't know this format", and only the former can be fixed by
/// supplying a different file of the same kind.
///
/// The distinction between `corruptedFile` and `truncated` is best-effort: SFB
/// surfaces both as generic input errors, so the module infers `truncated` only
/// when it can prove the on-disk length is shorter than the declared stream.
public enum DecodingError: Error, Sendable, Equatable {
    /// The file could not be read (missing, unreadable, permissions, device I/O).
    case ioError(url: URL, underlying: String)
    /// No registered decoder recognises the file's container or codec.
    case unsupportedFormat(url: URL)
    /// A decoder claimed the file but its contents are malformed / undecodable.
    case corruptedFile(url: URL, reason: String)
    /// The stream ends before the frame count promised by its header.
    case truncated(url: URL)
    /// The container/codec is supported but its sample rate is not convertible
    /// by this build. `detail` is a diagnostic token (e.g. `"DSD128 (5644800 Hz)"`),
    /// never user-facing copy — see ``message``.
    case unsupportedSampleRate(url: URL, detail: String)

    /// The file the failure relates to, for diagnostics and CLI reporting.
    public var url: URL {
        switch self {
        case let .ioError(url, _),
             let .unsupportedFormat(url),
             let .corruptedFile(url, _),
             let .truncated(url),
             let .unsupportedSampleRate(url, _):
            url
        }
    }

    /// The user-facing explanation, resolved through the String Catalog.
    ///
    /// Separate from ``description``, which stays an unlocalized diagnostic:
    /// a shell renders `message`, a log or the CLI renders `description`.
    public var message: LocalizedStringResource {
        switch self {
        case .ioError:
            DecodingStrings.errorIOError
        case .unsupportedFormat:
            DecodingStrings.errorUnsupportedFormat
        case .corruptedFile:
            DecodingStrings.errorCorruptedFile
        case .truncated:
            DecodingStrings.errorTruncated
        case .unsupportedSampleRate:
            DecodingStrings.errorUnsupportedSampleRate
        }
    }
}

// MARK: - Human-readable description

extension DecodingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .ioError(url, underlying):
            "I/O error reading \(url.lastPathComponent): \(underlying)"
        case let .unsupportedFormat(url):
            "unsupported audio format: \(url.lastPathComponent)"
        case let .corruptedFile(url, reason):
            "corrupted file \(url.lastPathComponent): \(reason)"
        case let .truncated(url):
            "truncated file (stream ends early): \(url.lastPathComponent)"
        case let .unsupportedSampleRate(url, detail):
            "unsupported sample rate for \(url.lastPathComponent): \(detail)"
        }
    }
}

extension DecodingError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}
