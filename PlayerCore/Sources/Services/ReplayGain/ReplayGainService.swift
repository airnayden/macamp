//
//  ReplayGainService.swift
//  MacAMP PlayerCore — Services
//
//  ReplayGain end-to-end integration: resolves the loudness/peak values for the
//  track being loaded, computes the gain to apply (mode + pre-amp + anti-clip +
//  clamp, via ``ReplayGainCalculator``), and contributes the result as the
//  ReplayGain summand of the engine's ``GainComposer``.
//
//  Resolution is a three-rung fallback — see ``ReplayGainSource``:
//
//    1. REPLAYGAIN_* tags on the file   (what whoever tagged it asked for)
//    2. the v18 `trackLoudness` cache   (what MacAMP measured itself)
//    3. unity                           (nothing to normalise against)
//
//  Every rung produces a ``ReplayGain`` that still goes through
//  ``ReplayGainCalculator`` — a synthesized value gets the same mode selection,
//  pre-amp, anti-clip limit and −96…+24 dB clamp a tagged one does.
//
//  Audio-thread rule: the gain is resolved and computed on track change (or a
//  settings change), NEVER on the render thread — and rung 2 is a GRDB read, so
//  ``apply(metadata:segment:)`` is `async` and belongs on the main actor at
//  track change. The engine applies the result through the EQ's `globalGain`
//  (Task 9) — there is no separate gain AU — and clipping is never permitted
//  (the computed value is anti-clip limited before it leaves here).
//
//  This file imports only AudioEngine + Metadata + Foundation; it MUST NOT
//  import AppKit or UIKit (PlayerCore portability invariant).
//

import AudioEngine
import Foundation
import Metadata

/// Wires ReplayGain end-to-end and pushes the computed gain to an injected
/// ``PlaybackEngine``'s gain composer on track change.
///
/// `@MainActor` because ``PlaybackEngine`` is main-actor isolated (the UI drives
/// the transport). The composer and the engine both re-clamp via
/// `clampGlobalGain(_:)`, so the value handed over is safe by construction *and*
/// defended in depth.
@MainActor
public final class ReplayGainService {
    /// Which ReplayGain reference to honor. Change then call ``reapply()``.
    public var mode: ReplayGainMode

    /// User pre-amplification (dB) added on top of the chosen gain. Change then
    /// call ``reapply()``.
    public var preamp: Double

    /// Which rung of the fallback supplied the values currently applied.
    ///
    /// This is the per-track "how is this normalised?" read-out, and it survives
    /// ``reapply()``: changing the mode or pre-amp re-computes a gain from the
    /// SAME resolved values, so their provenance is unchanged.
    public private(set) var source: ReplayGainSource = .unavailable

    private let calculator: ReplayGainComputing
    private let engine: any PlaybackEngine

    /// The analysis cache consulted when a file carries no tags. `nil` in a host
    /// with no database — every track then resolves to tags or unity.
    private let loudnessCache: (any TrackLoudnessReading)?

    /// Values for the currently-loaded track, retained so a mode/pre-amp change
    /// can be re-applied via ``reapply()`` without re-reading metadata or the
    /// database.
    private var current = ReplayGain()

    public init(
        engine: any PlaybackEngine,
        calculator: ReplayGainComputing = ReplayGainCalculator(),
        loudnessCache: (any TrackLoudnessReading)? = nil,
        mode: ReplayGainMode = .off,
        preamp: Double = 0
    ) {
        self.engine = engine
        self.calculator = calculator
        self.loudnessCache = loudnessCache
        self.mode = mode
        self.preamp = preamp
    }

    /// Computes the gain for `tags` under the current settings, pushes it to the
    /// engine, and returns it. Call this at render-start / on track change.
    @discardableResult
    public func apply(_ tags: ReplayGain) -> Double {
        adopt(tags, source: tags.isEmpty ? .unavailable : .tags)
    }

    /// Reads the ReplayGain field off `metadata` (missing → graceful 0 dB) and
    /// applies it.
    ///
    /// Tags only — this consults no cache. Use ``apply(metadata:segment:)`` on
    /// the playback path so an untagged-but-analysed track is still normalised.
    @discardableResult
    public func apply(metadata: TrackMetadata) -> Double {
        apply(metadata.replayGain ?? ReplayGain())
    }

    /// Resolves `metadata` through the three-rung fallback and applies the result.
    ///
    /// - Parameter segment: What is playing, so a cached measurement can be
    ///   matched against it. Pass `nil` for anything with no library row; the
    ///   fallback then stops at rung 1.
    @discardableResult
    public func apply(metadata: TrackMetadata, segment: ReplayGainSegment?) async -> Double {
        let resolution = await resolve(metadata: metadata, segment: segment)
        return adopt(resolution.tags, source: resolution.source)
    }

    /// Runs the three-rung fallback without touching the engine.
    ///
    /// Split out so a read-out can ask "what would this track resolve to?", and
    /// so the fallback is assertable independently of the push.
    public func resolve(
        metadata: TrackMetadata,
        segment: ReplayGainSegment?
    ) async -> ReplayGainResolution {
        if let tags = metadata.replayGain, !tags.isEmpty {
            return ReplayGainResolution(tags: tags, source: .tags)
        }
        if let cached = await cachedTags(for: segment) {
            return ReplayGainResolution(tags: cached, source: .computed)
        }
        return .unavailable
    }

    /// Re-computes and re-pushes using the last resolved values — use after the
    /// user changes ``mode`` or ``preamp`` mid-track.
    @discardableResult
    public func reapply() -> Double {
        push()
    }

    /// The dB the service *would* apply for `tags` right now, without touching the
    /// engine. Handy for settings previews and tests.
    public func computedGain(for tags: ReplayGain) -> Double {
        calculator.appliedGain(for: tags, mode: mode, preamp: preamp)
    }

    /// Rung 2: the cached measurement for `segment`, in tag shape.
    ///
    /// A row keyed to the right track but measured over DIFFERENT cue bounds is
    /// refused rather than served (``ReplayGainSegment/matches(_:)``). A read
    /// failure falls through to rung 3 — a database error may cost the listener
    /// a normalisation, never playback.
    private func cachedTags(for segment: ReplayGainSegment?) async -> ReplayGain? {
        // `track.id` is a rowid alias starting at 1, so a non-positive id is the
        // coordinator's "not a library track" sentinel, never a row to look up.
        guard let segment, segment.trackId > 0, let loudnessCache else { return nil }
        guard let record = try? await loudnessCache.loudness(forTrackId: segment.trackId),
              segment.matches(record)
        else { return nil }
        return ReplayGain(loudness: record)
    }

    /// Retains the resolved values + their provenance for ``reapply()``, then
    /// pushes the gain.
    @discardableResult
    private func adopt(_ tags: ReplayGain, source: ReplayGainSource) -> Double {
        current = tags
        self.source = source
        return push()
    }

    /// Hands the computed gain to the engine's ``GainComposer`` as the ReplayGain
    /// summand. Writing `setGlobalGain(_:)` here instead would erase the EQ
    /// pre-amp on every track change — the bug the composer exists to close.
    private func push() -> Double {
        let gain = calculator.appliedGain(for: current, mode: mode, preamp: preamp)
        engine.gainComposer.setReplayGain(Float(gain))
        return gain
    }
}
