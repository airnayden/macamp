// Value types for the library scanner/import pipeline (Task 13).
//
// These are the pure, transport-only models the ``LibraryScanner`` consumes and
// emits. They import only Foundation so the Services module stays portable
// (no AppKit/UIKit — PlayerCore invariant).
import Foundation

// MARK: - FileFingerprint

/// The cheap identity of a file on disk: its path plus the two attributes that
/// change when its bytes change.
///
/// On a re-scan the scanner compares the candidate's fingerprint against the
/// stored ``Persistence/TrackRecord`` (`mtime` + `fileSize`): equal ⇒ the row is
/// **skipped** without re-reading tags; different ⇒ the row is **updated**.
public struct FileFingerprint: Codable, Sendable, Equatable, Hashable {
    /// Absolute filesystem path (the `track.filePath` UNIQUE key).
    public var filePath: String
    /// Modification time, seconds since 1970.
    public var mtime: Double
    /// File size in bytes.
    public var fileSize: Int64

    public init(filePath: String, mtime: Double, fileSize: Int64) {
        self.filePath = filePath
        self.mtime = mtime
        self.fileSize = fileSize
    }
}

// MARK: - ScanCandidate

/// One file queued for import, paired with the fingerprint used to decide
/// insert / update / skip before any tag is read.
///
/// Directory/file sources build candidates by `stat`-ing the file; the
/// `.manifest` source carries them verbatim (pre-fingerprinted synthetic
/// candidates for perf tests that touch no filesystem).
public struct ScanCandidate: Sendable, Equatable {
    /// The file to read metadata from. For a cue segment this is the **AUDIO**
    /// file the sheet names, never the `.cue` sidecar — a sheet is text and must
    /// never enter the metadata-read path.
    public var url: URL
    /// The skip/update decision key. Every segment of one audio file carries that
    /// file's fingerprint; they are told apart by ``cue``'s start frame.
    public var fingerprint: FileFingerprint
    /// The sheet provenance when this candidate is one segment of a `.cue`, or
    /// `nil` for an ordinary whole-file import.
    public var cue: CueSegment?

    public init(url: URL, fingerprint: FileFingerprint, cue: CueSegment? = nil) {
        self.url = url
        self.fingerprint = fingerprint
        self.cue = cue
    }

    /// Builds a candidate whose fingerprint path is the URL's filesystem path.
    public init(url: URL, mtime: Double, fileSize: Int64, cue: CueSegment? = nil) {
        self.url = url
        fingerprint = FileFingerprint(filePath: url.path, mtime: mtime, fileSize: fileSize)
        self.cue = cue
    }
}

// MARK: - CueSegment

/// One `.cue` segment queued for import: the sheet it came from plus the single
/// track within it this candidate will become.
///
/// The sheet is carried whole rather than flattened so the disc-level `TITLE` /
/// `PERFORMER` / `REM GENRE` / `REM DATE` stay available as album fields. Swift's
/// copy-on-write means the N segments of one sheet share its `tracks` storage.
public struct CueSegment: Sendable, Equatable {
    public var sheet: CueSheet
    public var track: CueTrack

    public init(sheet: CueSheet, track: CueTrack) {
        self.sheet = sheet
        self.track = track
    }
}

// MARK: - ScanRequest

/// What to import.
///
/// - `directory`: recursive walk, filtered to audio extensions.
/// - `files`: an explicit list of file URLs.
/// - `manifest`: pre-fingerprinted candidates (synthetic perf tests).
public enum ScanRequest: Sendable {
    case directory(URL)
    case files([URL])
    case manifest([ScanCandidate])
}

// MARK: - ScanProgress

/// Incremental progress, emitted at every chunk boundary.
public struct ScanProgress: Codable, Sendable, Equatable {
    /// Candidates accounted for so far (added + updated + skipped + failed).
    public var processed: Int
    /// Total candidates resolved for this scan.
    public var total: Int
    /// The last path handled in the most recent chunk (for UI display).
    public var currentPath: String?

    public init(processed: Int, total: Int, currentPath: String? = nil) {
        self.processed = processed
        self.total = total
        self.currentPath = currentPath
    }

    /// Completion fraction in `0...1` (0 when the total is unknown).
    public var fraction: Double {
        total > 0 ? Double(processed) / Double(total) : 0
    }
}

// MARK: - ScanSummary

/// The final tally an import produces.
public struct ScanSummary: Codable, Sendable, Equatable {
    /// New rows inserted.
    public var added: Int
    /// Existing rows whose fingerprint changed and were re-read.
    public var updated: Int
    /// Existing rows whose fingerprint matched and were left untouched.
    public var skipped: Int
    /// Candidates whose metadata could not be read (or that failed to persist).
    public var failed: Int

    public init(added: Int = 0, updated: Int = 0, skipped: Int = 0, failed: Int = 0) {
        self.added = added
        self.updated = updated
        self.skipped = skipped
        self.failed = failed
    }

    /// Total candidates accounted for.
    public var total: Int {
        added + updated + skipped + failed
    }

    /// Accumulates a chunk's tally into the running total.
    public mutating func add(_ other: ScanSummary) {
        added += other.added
        updated += other.updated
        skipped += other.skipped
        failed += other.failed
    }
}

// MARK: - ScanEvent

/// A streamed scan event: zero or more `.progress` then exactly one `.finished`.
public enum ScanEvent: Sendable, Equatable {
    case progress(ScanProgress)
    case finished(ScanSummary)
}
