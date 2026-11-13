// MetadataError — the typed error model for MacAMP's metadata layer.
//
// Every failure path in the Metadata module surfaces as a `MetadataError`.
// Corrupt, unsupported and unreadable inputs are ALWAYS mapped to one of these
// cases — the module never force-unwraps, never traps, and never lets a raw
// SFBAudioEngine / Foundation `NSError` escape to callers. This mirrors the
// Decoding module's `DecodingError` so the two read-side layers share one
// error-handling shape.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// A typed, `Sendable` description of why metadata could not be read.
///
/// The three cases triage from "we can't read the bytes" up to "the bytes are
/// there but malformed":
///
/// - ``ioError(url:underlying:)`` — the file could not be read at all (missing,
///   permissions, a device error). The underlying message is preserved verbatim.
/// - ``unsupportedFormat(url:)`` — the bytes were read but no registered reader
///   recognises the container/codec (wrong extension, an exotic format, …).
/// - ``corruptedFile(url:reason:)`` — a reader *did* claim the file but its tag
///   stream is malformed (bad atoms, garbage payload, failed parse).
public enum MetadataError: Error, Sendable, Equatable {
    /// The file could not be read (missing, unreadable, permissions, device I/O).
    case ioError(url: URL, underlying: String)
    /// No registered reader recognises the file's container or codec.
    case unsupportedFormat(url: URL)
    /// A reader claimed the file but its tag stream is malformed / unparsable.
    case corruptedFile(url: URL, reason: String)

    /// The file the failure relates to, for diagnostics and CLI reporting.
    public var url: URL {
        switch self {
        case let .ioError(url, _),
             let .unsupportedFormat(url),
             let .corruptedFile(url, _):
            url
        }
    }
}

// MARK: - Human-readable description

extension MetadataError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .ioError(url, underlying):
            "I/O error reading \(url.lastPathComponent): \(underlying)"
        case let .unsupportedFormat(url):
            "unsupported audio format: \(url.lastPathComponent)"
        case let .corruptedFile(url, reason):
            "corrupted file \(url.lastPathComponent): \(reason)"
        }
    }
}

extension MetadataError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}
