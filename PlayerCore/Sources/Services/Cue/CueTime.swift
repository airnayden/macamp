// CueTime — MM:SS:FF timecode arithmetic at the Red Book 75 frames-per-second rate.
//
// Every position in a CUE sheet is a CD *frame* (a sector), exactly 1/75 of a second.
// This type is the single place that conversion lives so no caller ever open-codes the
// 75 multiplier. It does no I/O, touches no audio, and knows nothing about decoders —
// it is pure integer arithmetic, which is what makes the whole parser table-testable.
//
// Frames are the canonical unit the persistence layer stores (`track.cueStartFrame` /
// `cueEndFrame`); samples are derived on demand at the decoder seam.
import Foundation

/// A CUE sheet timecode: minutes, seconds, and CD frames (1/75 s).
public struct CueTime: Equatable, Hashable, Sendable, Comparable {
    /// Red Book sector rate. A CD carries exactly 75 frames per second — this is a
    /// format constant, never a tunable.
    public static let framesPerSecond = 75

    public let minutes: Int
    public let seconds: Int
    public let frames: Int

    /// The position expressed as a single frame count: `(MM·60 + SS)·75 + FF`.
    public var totalFrames: Int {
        (minutes * 60 + seconds) * Self.framesPerSecond + frames
    }

    /// Builds a timecode from already-validated components.
    ///
    /// Out-of-range `seconds`/`frames` are accepted here (they simply carry into
    /// ``totalFrames``); the *parser* is what rejects them, because a sheet writing
    /// `00:75:00` is malformed input rather than a legal 75-second offset.
    public init(minutes: Int, seconds: Int, frames: Int) {
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    /// Parses the `MM:SS:FF` form, returning `nil` for anything that is not exactly
    /// three all-ASCII-digit components with `SS < 60` and `FF < 75`.
    ///
    /// `MM` is deliberately unbounded in digit count: a single-file rip of a long disc
    /// legitimately reaches `79:57:74`, and some sheets for non-CD sources exceed two
    /// digits entirely.
    public init?(timecode: String) {
        let parts = timecode.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let minutes = Self.asciiDigits(parts[0]),
              let seconds = Self.asciiDigits(parts[1]),
              let frames = Self.asciiDigits(parts[2]),
              seconds < 60,
              frames < Self.framesPerSecond
        else {
            return nil
        }
        self.init(minutes: minutes, seconds: seconds, frames: frames)
    }

    public static func < (lhs: CueTime, rhs: CueTime) -> Bool {
        lhs.totalFrames < rhs.totalFrames
    }

    /// The sample offset this position lands on at `sampleRate`.
    ///
    /// Exact for every rate that is a multiple of 75 — which is all of them in practice
    /// (44100 → 588 samples/frame, 48000 → 640, 96000 → 1280, 192000 → 2560). For any
    /// other rate the result floors, matching the decoder seam's frame-clamp semantics.
    public func samples(atSampleRate sampleRate: Int) -> Int64 {
        Self.samples(frames: totalFrames, sampleRate: sampleRate)
    }

    /// `frames · sampleRate / 75`, computed in 64-bit so a long disc at 192 kHz cannot
    /// overflow on a 32-bit intermediate.
    public static func samples(frames: Int, sampleRate: Int) -> Int64 {
        Int64(frames) * Int64(sampleRate) / Int64(framesPerSecond)
    }

    /// Wall-clock seconds for a frame count. Used for cue-track durations, where the
    /// sample rate is irrelevant because both ends are already frames.
    public static func seconds(frames: Int) -> Double {
        Double(frames) / Double(framesPerSecond)
    }

    /// `Int(text)` restricted to non-empty, all-ASCII-digit input.
    ///
    /// `Character.isNumber` alone would accept Eastern Arabic-Indic digits and other
    /// Unicode numerals that `Int(_:)` then rejects, so the ASCII check is what keeps
    /// "parsed" and "convertible" the same predicate.
    private static func asciiDigits(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return Int(text)
    }
}
