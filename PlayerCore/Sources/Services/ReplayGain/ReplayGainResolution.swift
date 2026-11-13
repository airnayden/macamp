//
//  ReplayGainResolution.swift
//  MacAMP PlayerCore — Services
//
//  Where a track's playback gain comes from when the file itself carries no
//  REPLAYGAIN_* tags: the v18 `trackLoudness` analysis cache, and failing that,
//  unity.
//
//  The vocabulary lives beside ``ReplayGainService`` rather than in the cache's
//  own module because it answers a PLAYBACK question.
//  ``TrackLoudnessRepository`` answers "what did the scanner measure?"; this
//  answers "what should the engine apply for the thing that is playing right
//  now?". ``TrackLoudnessReading`` narrows the repository to the one read that
//  question needs, so the playback path cannot reach `upsert` / `deleteAll`
//  even by accident.
//
//  Nothing here computes a gain. A resolved ``ReplayGain`` is still handed to
//  ``ReplayGainCalculator`` for mode selection, pre-amp, anti-clip and the
//  −96…+24 dB clamp — a synthesized value takes exactly the same path a tagged
//  one does.
//
//  This file imports only Metadata + Persistence; it MUST NOT import AppKit or
//  UIKit (PlayerCore portability invariant).
//

import Metadata
import Persistence

// MARK: - TrackLoudnessReading

/// The one cached-loudness read the playback path performs.
///
/// Deliberately narrower than ``TrackLoudnessRepositoryProviding``: playback
/// reads the analysis cache and must never write it, and a seam that cannot
/// express a write cannot perform one. It is also a one-method protocol, so a
/// test double is a handful of lines rather than seven stubs.
public protocol TrackLoudnessReading: Sendable {
    /// One track's cached loudness, or `nil` when it has never been analysed.
    func loudness(forTrackId trackId: Int64) async throws -> TrackLoudnessRecord?
}

extension TrackLoudnessRepository: TrackLoudnessReading {}

// MARK: - ReplayGainSegment

/// The track — or cue segment of a track — whose cached loudness is wanted.
///
/// The `trackLoudness` row is keyed by `trackId` ALONE, while its cue bounds are
/// part of the fingerprint it was measured under. Carrying the bounds here is
/// what lets ``matches(_:)`` refuse a row that describes a different segment of
/// the same audio file. Every non-cue track is the degenerate whole-file case,
/// which is what ``wholeFile(trackId:)`` spells.
public struct ReplayGainSegment: Sendable, Equatable, Hashable {
    /// The `cueStartFrame` a whole file is recorded under (as opposed to a cue
    /// segment). Shared with ``TrackLoudnessFingerprint`` so the two sentinels
    /// can never drift apart.
    public static let wholeFileCueStartFrame = TrackLoudnessFingerprint.wholeFileCueStartFrame

    /// `track.id` of the playing track.
    public let trackId: Int64
    /// First frame played, or ``wholeFileCueStartFrame`` for a whole file.
    public let cueStartFrame: Int64
    /// Exclusive last frame played, or `nil` for "to end of file".
    public let cueEndFrame: Int64?

    public init(
        trackId: Int64,
        cueStartFrame: Int64 = ReplayGainSegment.wholeFileCueStartFrame,
        cueEndFrame: Int64? = nil
    ) {
        self.trackId = trackId
        self.cueStartFrame = cueStartFrame
        self.cueEndFrame = cueEndFrame
    }

    /// The whole of `trackId` — the shape every non-cue track plays as.
    public static func wholeFile(trackId: Int64) -> ReplayGainSegment {
        ReplayGainSegment(trackId: trackId)
    }

    /// Whether `record` measured exactly this segment.
    ///
    /// Until v20 gives `track` its own cue columns every playing track IS a
    /// whole file, so this comparison is what keeps that a checked fact rather
    /// than an assumption — and it is already correct for the cue rows todo 31
    /// will start playing.
    public func matches(_ record: TrackLoudnessRecord) -> Bool {
        record.cueStartFrame == cueStartFrame && record.cueEndFrame == cueEndFrame
    }
}

// MARK: - ReplayGainSource

/// Which of the three fallback rungs supplied the gain currently applied.
///
/// Named ``unavailable`` rather than `none` on purpose: a static called `none`
/// silently resolves to `Optional.none` at any call site that stores it as an
/// optional.
public enum ReplayGainSource: Sendable, Equatable, Hashable, CaseIterable {
    /// REPLAYGAIN_* tags read off the file. Always preferred — they are what the
    /// person who tagged the file asked for.
    case tags
    /// Synthesized from a cached BS.1770-4 measurement (`trackLoudness`).
    case computed
    /// Neither — playback runs at unity, and the track is a candidate for the
    /// next analysis pass.
    case unavailable
}

// MARK: - ReplayGainResolution

/// The outcome of the three-way fallback, before the engine is touched.
public struct ReplayGainResolution: Sendable, Equatable {
    /// The tag values to compute a gain from. Empty for ``ReplayGainSource/unavailable``.
    public let tags: ReplayGain
    /// Which rung supplied ``tags``.
    public let source: ReplayGainSource

    public init(tags: ReplayGain, source: ReplayGainSource) {
        self.tags = tags
        self.source = source
    }

    /// Nothing to normalise against — unity, and no measurement to blame.
    public static let unavailable = ReplayGainResolution(tags: ReplayGain(), source: .unavailable)
}

// MARK: - Cached measurement -> tags

public extension ReplayGain {
    /// A cached BS.1770-4 measurement in the tag shape the calculator consumes.
    ///
    /// `gain = −18 − LUFS` for both scopes, via ``ReplayGainSynthesis`` so the
    /// mapping has exactly one definition shared with the scanner that wrote the
    /// row. An absent LUFS stays absent — todo 4's silence sentinel is a real
    /// answer ("no block cleared −70 LKFS"), and substituting `0` would claim the
    /// file is already at the reference level. `truePeak` is always present, so
    /// even a sentinel row still carries the anti-clip limit.
    init(loudness record: TrackLoudnessRecord) {
        self.init(
            referenceLoudness: ReplayGainSynthesis.referenceLoudnessLUFS,
            trackGain: ReplayGainSynthesis.gainDB(forIntegratedLUFS: record.integratedLUFS),
            trackPeak: record.truePeak,
            albumGain: ReplayGainSynthesis.gainDB(forIntegratedLUFS: record.albumLUFS),
            albumPeak: record.albumPeak
        )
    }
}
