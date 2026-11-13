// CueAudioFileLocating — the parser's only filesystem seam.
//
// A `FILE` operand is a bare, sheet-relative name; turning it into an absolute path is
// the one step that touches disk. It is a protocol so the parser itself stays pure and
// hermetically testable, and so the resolution policy can be swapped without reopening
// the grammar.
//
// This seam checks EXISTENCE only. It never opens, decodes, or reads tags from the file —
// the parser must not enter the decode or metadata-read paths.
import Foundation

/// Resolves a `FILE` operand to an absolute audio path, or `nil` when none exists.
public protocol CueAudioFileLocating: Sendable {
    /// - Parameters:
    ///   - fileName: the operand exactly as written in the sheet.
    ///   - directory: the directory containing the `.cue` file.
    /// - Returns: the absolute path of the audio file, or `nil` when it cannot be found.
    func locate(fileName: String, relativeTo directory: URL) -> String?
}

/// The production locator: `FileManager` existence checks, plus a bounded extension
/// fallback.
///
/// # Why the fallback exists
/// Rippers write the name of the file they produced at rip time, which is routinely a
/// `.wav` that was encoded to FLAC afterwards and deleted. Sheets in the wild therefore
/// name `01 - Track.wav` next to an on-disk `01 - Track.flac`. Without the fallback those
/// albums resolve to nothing at all, which is the single most common cue-import failure.
///
/// The fallback is deliberately narrow: the SAME basename in the SAME directory, tried
/// against a fixed extension list. It never searches, never recurses, and never guesses
/// at a different name.
public struct FileManagerCueAudioFileLocator: CueAudioFileLocating {
    /// Extensions tried when the literal operand is absent, in preference order.
    /// Lossless first — a sheet describes a CD rip, so a FLAC sibling is a far more
    /// likely match than a lossy one.
    public static let fallbackExtensions = [
        "flac", "wav", "ape", "wv", "aiff", "aif", "tta", "m4a", "alac", "ogg", "opus", "mp3",
    ]

    public init() {}

    public func locate(fileName: String, relativeTo directory: URL) -> String? {
        let literal = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: literal.path) {
            return literal.path
        }
        return siblingWithKnownExtension(of: literal)
    }

    /// The same basename in the same directory carrying one of
    /// ``fallbackExtensions``. Returns `nil` when the operand had no extension to
    /// replace, so a directory name can never be mistaken for a track.
    private func siblingWithKnownExtension(of literal: URL) -> String? {
        guard !literal.pathExtension.isEmpty else {
            return nil
        }
        let stem = literal.deletingPathExtension()
        for candidateExtension in Self.fallbackExtensions {
            let candidate = stem.appendingPathExtension(candidateExtension)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}
