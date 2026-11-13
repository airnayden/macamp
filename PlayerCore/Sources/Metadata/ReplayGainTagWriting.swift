// ReplayGainTagWriting — the explicit, user-invoked "Write ReplayGain Tags" action.
//
// NOTHING IN MACAMP WRITES REPLAYGAIN TAGS AUTOMATICALLY. Scanned loudness lives
// in the `trackLoudness` database table and is applied at playback through the EQ
// unit's global gain; putting it on disk mutates the user's files, so it happens
// only when the user asks for it. This type is the single door for that action.
//
// It adds exactly one thing on top of ``MetadataWriting``: a per-format refusal
// policy. ``SFBMetadataWriter``'s preflight accepts every extension its backend
// can open, which is wider than the set that can actually carry RG 2.0 tags — so
// without this gate the action would "succeed" on formats where the tags are
// dropped or mean something else. See ``ReplayGainTagSupport`` for the measured
// reasons behind each refusal.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant), and — like the rest of the Metadata module —
// it never touches the database. The caller supplies already-derived figures.
import Foundation

// MARK: - ReplayGainTagWriting

/// Writes measured ReplayGain figures to a file's tags, on explicit user request.
public protocol ReplayGainTagWriting: Sendable {
    /// Writes `values` to the tags of the file at `url`, leaving every other tag
    /// untouched.
    ///
    /// - Throws: ``ReplayGainTagWriteError``. The file is byte-for-byte unchanged
    ///   whenever this throws, including the refusal paths — those are decided
    ///   from the path extension alone, before any I/O.
    func writeReplayGainTags(_ values: ReplayGainTagValues, to url: URL) throws
}

// MARK: - ReplayGainTagValues

/// The four RG 2.0 figures to stamp onto a file.
///
/// Sourced from the `trackLoudness` row: the two gains are that row's LUFS
/// readings already converted by `ReplayGainSynthesis.gainDB(forIntegratedLUFS:)`,
/// and the two peaks are its linear `truePeak` / `albumPeak` verbatim. The
/// conversion deliberately stays with the caller — the reference-loudness constant
/// has exactly one definition, in `Services`, and re-deriving it here would make
/// two.
///
/// `nil` means *leave that tag as it is on disk*, which is also how a silent track
/// travels: `gainDB(forIntegratedLUFS:)` answers `nil` rather than `0` when no
/// block cleared the absolute gate, and claiming such a file is already at
/// reference would be worse than leaving it untagged.
public struct ReplayGainTagValues: Sendable, Equatable, Hashable {
    /// `REPLAYGAIN_TRACK_GAIN`, dB relative to the reference loudness.
    public var trackGainDB: Double?
    /// `REPLAYGAIN_TRACK_PEAK`, linear (`1.0` == full scale; above 1.0 is normal).
    public var trackPeak: Double?
    /// `REPLAYGAIN_ALBUM_GAIN`, dB relative to the reference loudness.
    public var albumGainDB: Double?
    /// `REPLAYGAIN_ALBUM_PEAK`, linear peak across the album.
    public var albumPeak: Double?

    public init(
        trackGainDB: Double? = nil,
        trackPeak: Double? = nil,
        albumGainDB: Double? = nil,
        albumPeak: Double? = nil
    ) {
        self.trackGainDB = trackGainDB
        self.trackPeak = trackPeak
        self.albumGainDB = albumGainDB
        self.albumPeak = albumPeak
    }

    /// `true` when every figure is absent, so there is nothing to stamp.
    public var isEmpty: Bool {
        trackGainDB == nil && trackPeak == nil && albumGainDB == nil && albumPeak == nil
    }

    /// The equivalent tag patch — ReplayGain only, every other field left alone.
    public var patch: WritableMetadata {
        WritableMetadata(
            replayGainTrackGain: trackGainDB,
            replayGainTrackPeak: trackPeak,
            replayGainAlbumGain: albumGainDB,
            replayGainAlbumPeak: albumPeak
        )
    }
}

// MARK: - ReplayGainTagSupport

/// Which formats MacAMP will stamp RG 2.0 tags onto, and why it refuses the rest.
///
/// An **allow-list**, deliberately: a refusal is visible and recoverable, whereas
/// a write that lands nowhere is a silent lie about the user's files.
public enum ReplayGainTagSupport {
    /// Lower-cased path extensions whose RG 2.0 round-trip is verified end to end
    /// (write through ``SFBMetadataWriter``, re-read through ``SFBMetadataReader``,
    /// tag text confirmed present in the file's raw bytes).
    public static let writableExtensions: Set<String> = ["mp3", "flac"]

    private static let oggFamily: Set<String> = ["ogg", "oga", "opus", "spx"]
    private static let mp4Family: Set<String> = ["m4a", "mp4", "m4b", "m4r", "aac"]

    /// `nil` when `pathExtension` is supported, otherwise why it is refused.
    public static func unsupportedReason(
        forPathExtension pathExtension: String
    ) -> ReplayGainTagUnsupportedReason? {
        let ext = pathExtension.lowercased()
        if writableExtensions.contains(ext) { return nil }
        if oggFamily.contains(ext) { return .oggFamilyMayCarryR128 }
        if mp4Family.contains(ext) { return .mp4BackendDiscardsTags }
        return .formatNotVerified
    }

    /// `nil` when the file at `url` is supported, otherwise why it is refused.
    public static func unsupportedReason(for url: URL) -> ReplayGainTagUnsupportedReason? {
        unsupportedReason(forPathExtension: url.pathExtension)
    }
}

/// Why a format is refused for ReplayGain tag writing.
public enum ReplayGainTagUnsupportedReason: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Ogg-family container (`.ogg`/`.oga`/`.opus`/`.spx`).
    ///
    /// Opus normalises against `R128_TRACK_GAIN` — Q7.8 fixed point referenced to
    /// −23 LUFS — while these figures are RG 2.0 dB referenced to −18 LUFS. Writing
    /// one as the other is a 5 dB error that no player reports. The extension
    /// cannot prove the stream is Vorbis rather than Opus (both use `.ogg`), so the
    /// whole family is refused rather than guessed at.
    case oggFamilyMayCarryR128

    /// MP4-family container (`.m4a`/`.mp4`/`.m4b`/`.m4r`/`.aac`).
    ///
    /// Measured on the pinned SFBAudioEngine 0.12.1 / CXXTagLib 2.1.x pair: SFB
    /// names the freeform atoms `---:com.apple.iTunes:replaygain_*` (three hyphens)
    /// while TagLib treats a name as freeform only when it begins `----` (four).
    /// The items are therefore dropped at render time — the rest of the write still
    /// commits, so the file looks tagged and is not. Refusing is the only honest
    /// answer until the backend moves.
    case mp4BackendDiscardsTags

    /// Anything else. The backend may well accept the file, but no round-trip has
    /// been verified for it, and an unverified stamp is indistinguishable from a
    /// lost one.
    case formatNotVerified
}

// MARK: - ReplayGainTagWriteError

/// A typed, `Sendable` description of why ReplayGain tags were not written.
///
/// The file is byte-for-byte unchanged in every case.
public enum ReplayGainTagWriteError: Error, Sendable, Equatable {
    /// The format cannot carry RG 2.0 tags meaningfully. Decided from the path
    /// extension alone — the file is never opened.
    case unsupportedFormat(url: URL, reason: ReplayGainTagUnsupportedReason)
    /// Every figure was absent, so the action would have been a no-op. Surfaced
    /// rather than silently skipped so the caller can say why nothing happened.
    case noValuesToWrite(url: URL)
    /// The underlying atomic tag write refused or failed.
    case writeFailed(url: URL, underlying: MetadataWriteError)

    /// The file the failure relates to, for diagnostics and UI reporting.
    public var url: URL {
        switch self {
        case let .unsupportedFormat(url, _),
             let .noValuesToWrite(url),
             let .writeFailed(url, _):
            url
        }
    }
}

extension ReplayGainTagWriteError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .unsupportedFormat(url, reason):
            "cannot write ReplayGain tags to \(url.lastPathComponent): \(reason.rawValue)"
        case let .noValuesToWrite(url):
            "no measured ReplayGain to write for \(url.lastPathComponent)"
        case let .writeFailed(_, underlying):
            underlying.description
        }
    }
}

extension ReplayGainTagWriteError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}

// MARK: - ReplayGainTagWriter

/// The production ``ReplayGainTagWriting``: gate, then delegate to the atomic
/// ``MetadataWriting`` backend.
///
/// It adds no file handling of its own, so the temp-copy + rename contract,
/// rollback, self-write suppression and the re-import hook all behave exactly as
/// they do for any other tag edit.
public struct ReplayGainTagWriter: ReplayGainTagWriting {
    private let writer: any MetadataWriting

    public init(writer: any MetadataWriting = SFBMetadataWriter()) {
        self.writer = writer
    }

    public func writeReplayGainTags(_ values: ReplayGainTagValues, to url: URL) throws {
        if let reason = ReplayGainTagSupport.unsupportedReason(for: url) {
            throw ReplayGainTagWriteError.unsupportedFormat(url: url, reason: reason)
        }
        guard !values.isEmpty else {
            throw ReplayGainTagWriteError.noValuesToWrite(url: url)
        }
        do {
            try writer.writeMetadata(values.patch, to: url)
        } catch let error as MetadataWriteError {
            throw ReplayGainTagWriteError.writeFailed(url: url, underlying: error)
        }
    }
}
