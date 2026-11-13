// TrackRef — a lightweight, value-typed reference to a queued track.
//
// The coordinator's queue is a list of these, NOT of `TrackRecord`s: a ref
// carries only what the now-playing layer needs (a file URL to hand the engine,
// the availability state used to skip missing files, and a little display text),
// so the hot path never touches the database. Each ref owns a stable ``id`` (a
// fresh `UUID` per construction) so the same file can appear twice in a queue and
// be reordered/removed unambiguously, and so snapshots round-trip by identity.
//
// A ref also carries the CUE SEGMENT bounds (v20 `track.cueStartFrame` /
// `cueEndFrame`) when it names one segment of a single-file album rip, because the
// coordinator resolves a playable ``DecoderSource`` synchronously and must never
// read the database to learn where a segment starts. The two fields are the whole
// of what the queue needs: everything else about a segment (title, duration,
// stream properties) is already an ordinary ref field.
//
// This file imports only AVFAudio + Persistence (for ``Availability``) +
// Foundation; it MUST NOT import AppKit or UIKit (PlayerCore portability
// invariant).
import AVFAudio
import Foundation
import Persistence

/// A value-typed reference to a track in the playback queue.
///
/// Construct directly, or from a ``TrackRecord`` via ``init(record:id:)``. The
/// backing file is addressed by ``url`` (derived from ``filePath``); a ref whose
/// ``availability`` is not ``Availability/present`` is skipped during playback.
public struct TrackRef: Identifiable, Sendable, Equatable, Hashable, Codable {
    /// Stable per-instance identity (unique even for duplicate files in a queue).
    public let id: UUID
    /// The originating `track.id` primary key, when this ref came from a record.
    public let trackID: Int64?
    /// Absolute file path of the backing audio file.
    public let filePath: String
    /// Display title, if known.
    public let title: String?
    /// Display artist, if known.
    public let artist: String?
    /// Duration in seconds, if known.
    public let duration: TimeInterval?
    /// Nominal bitrate in bits/second, if known.
    public let bitrate: Int?
    /// Sample rate in Hz, if known.
    public let sampleRate: Int?
    /// Backing-file availability — `.missing` / `.externalOffline` refs are skipped.
    public let availability: Availability
    /// Where this cue segment starts inside ``filePath``, in CD frames (75 per
    /// second — ``CueTime/framesPerSecond``), or `nil` for a whole file.
    ///
    /// `nil` is the ref-level spelling of `track.cueStartFrame`'s `-1` sentinel.
    /// Declared `Optional` rather than defaulted-`Int64` on purpose: a persisted
    /// ``CoordinatorSnapshot`` predating v20 carries neither key, and the synthesised
    /// `Decodable` only tolerates a missing key for an `Optional`.
    public let cueStartFrame: Int64?
    /// Where this cue segment ends, EXCLUSIVE, in CD frames — or `nil` for "to end
    /// of file", which is what a `FILE` block's last segment carries.
    public let cueEndFrame: Int64?

    public init(
        id: UUID = UUID(),
        trackID: Int64? = nil,
        filePath: String,
        title: String? = nil,
        artist: String? = nil,
        duration: TimeInterval? = nil,
        bitrate: Int? = nil,
        sampleRate: Int? = nil,
        availability: Availability = .present,
        cueStartFrame: Int64? = nil,
        cueEndFrame: Int64? = nil
    ) {
        self.id = id
        self.trackID = trackID
        self.filePath = filePath
        self.title = title
        self.artist = artist
        self.duration = duration
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.availability = availability
        self.cueStartFrame = cueStartFrame
        self.cueEndFrame = cueEndFrame
    }

    /// Builds a ref from a persisted ``TrackRecord``, copying the denormalised
    /// artist text and the availability state the scanner recorded.
    public init(record: TrackRecord, id: UUID = UUID()) {
        self.init(
            id: id,
            trackID: record.id,
            filePath: record.filePath,
            title: record.title,
            artist: record.artistName,
            duration: record.duration,
            bitrate: record.bitrate,
            sampleRate: record.sampleRate,
            availability: record.availability,
            cueStartFrame: record.isCueSegment ? record.cueStartFrame : nil,
            cueEndFrame: record.isCueSegment ? record.cueEndFrame : nil
        )
    }

    /// The backing file as a `file://` URL handed to the engine's `load`/`enqueue`.
    public var url: URL {
        URL(fileURLWithPath: filePath)
    }

    /// Whether this ref's backing file is present and therefore playable now.
    public var isPlayable: Bool {
        availability == .present
    }

    /// Whether this ref names one segment of a `.cue` sheet rather than a whole file.
    public var isCueSegment: Bool {
        cueStartFrame != nil
    }

    /// The v20 `UNIQUE(filePath, cueStartFrame)` row identity this ref came from.
    ///
    /// One audio file backs N rows once a `.cue` sheet names it, so anything that
    /// maps a ref to per-track state keys on this — never on ``filePath`` alone.
    public var identity: TrackRecord.Identity {
        TrackRecord.Identity(
            filePath: filePath,
            cueStartFrame: cueStartFrame ?? TrackRecord.wholeFileCueStartFrame
        )
    }

    /// The half-open SAMPLE range this ref plays inside ``url``, or `nil` for a
    /// whole file.
    ///
    /// Cue offsets are stored in CD frames, so they are converted through
    /// ``CueTime/samples(frames:sampleRate:)`` — the one place the 75 lives. An
    /// open-ended segment (`cueEndFrame == nil`) reports `AVAudioFramePosition.max`
    /// as its upper bound rather than a computed file length: the decoder backend
    /// knows the true length and clamps there, so guessing it here could only be
    /// wrong. A ref with no known sample rate, or a non-advancing range, resolves to
    /// `nil` so the whole file plays instead of nothing.
    public var segmentFrameRange: Range<AVAudioFramePosition>? {
        guard let cueStartFrame, let sampleRate, sampleRate > 0 else { return nil }
        let start = CueTime.samples(frames: Int(cueStartFrame), sampleRate: sampleRate)
        guard let cueEndFrame else { return start ..< AVAudioFramePosition.max }
        let end = CueTime.samples(frames: Int(cueEndFrame), sampleRate: sampleRate)
        guard end > start else { return nil }
        return start ..< end
    }
}
