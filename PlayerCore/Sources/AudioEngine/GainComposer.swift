// GainComposer — the single owner of a playback engine's global gain.
//
// Before this type existed every gain contributor wrote `setGlobalGain(_:)`
// directly, so the ONE slot behind it was last-writer-wins: applying an EQ preset
// with a −6 dB pre-amp overwrote the ReplayGain trim, and the next track change
// re-pushed ReplayGain and silently reset the pre-amp (the delegate proxy's
// `renderingWillStart` then re-stamped that ReplayGain-only value onto the EQ for
// every decoder). The composer replaces that race with one arithmetic rule: each
// contributor owns its OWN summand, the composer sums them, clamps once, and is
// the only code that touches the engine's gain port.
//
// It is also the single READ source of truth for the composed gain: the
// signal-path panel and the head-room meter both consume ``composedGainDB``
// rather than re-deriving the sum from the individual contributors.
//
// ANTI-CLIP CAVEAT (recorded deliberately): `ReplayGainCalculator` anti-clip
// limits its own summand against `REPLAYGAIN_TRACK_PEAK`, so on its own that
// summand can never drive the output above full scale. Once the composer adds
// POSITIVE pre-amps (graphic, parametric, AutoEq) on top of it, that ceiling is
// ADVISORY rather than end-to-end guaranteed — the sum may exceed what the
// anti-clip limit reserved. The compensating control is the head-room
// suggestion, which measures the compound peak and offers an explicit trim
// through ``setHeadroomTrim(_:)``. The anti-clip math itself is unchanged: it
// still bounds the ReplayGain summand exactly as before.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// Sums every contribution to a playback engine's global gain and pushes the
/// clamped total to that engine.
///
/// Four independent contributors write their own summand and never each other's:
///
/// | Summand | Written by |
/// |---|---|
/// | ``replayGainDB`` | the ReplayGain service, on track / settings change |
/// | ``graphicPreampDB`` | the ten-band graphic EQ, when a preset is applied |
/// | ``parametricPreampDB`` | the parametric EQ (an AutoEq profile's pre-amp line) |
/// | ``headroomTrimDB`` | an explicit, user-accepted head-room trim |
///
/// Every setter recomposes and pushes, so the engine's gain always equals
/// ``composedGainDB`` — including across a track change, because the engine
/// re-stamps its stored value (already the composed total) for each decoder.
///
/// `@MainActor` because ``PlaybackEngine`` is: the composer is a thin ledger in
/// front of the transport, never a concurrency boundary.
@MainActor
public final class GainComposer {
    /// The ReplayGain trim (dB) — already mode-selected and anti-clip limited by
    /// `ReplayGainCalculator`.
    public private(set) var replayGainDB: Float = 0
    /// The ten-band graphic EQ's pre-amp (dB), from the applied preset.
    public private(set) var graphicPreampDB: Float = 0
    /// The parametric EQ's pre-amp (dB), e.g. an AutoEq profile's `Preamp:` line.
    public private(set) var parametricPreampDB: Float = 0
    /// An explicit head-room trim (dB, normally negative) the user accepted.
    public private(set) var headroomTrimDB: Float = 0

    /// The clamped sum of all four contributions — exactly the value the engine
    /// is holding. Read this instead of re-deriving the sum; it is the one
    /// answer to "how much gain is this signal path applying?".
    public var composedGainDB: Float {
        clampGlobalGain(replayGainDB + graphicPreampDB + parametricPreampDB + headroomTrimDB)
    }

    /// Weak so a composer parked in the registry never keeps a dead engine alive.
    private weak var engine: (any PlaybackEngine)?

    init(engine: any PlaybackEngine) {
        self.engine = engine
    }

    /// Replaces the ReplayGain summand and re-pushes the composed total.
    public func setReplayGain(_ decibels: Float) {
        guard replayGainDB != decibels else { return }
        replayGainDB = decibels
        commit()
    }

    /// Replaces the graphic-EQ pre-amp summand and re-pushes the composed total.
    public func setGraphicPreamp(_ decibels: Float) {
        guard graphicPreampDB != decibels else { return }
        graphicPreampDB = decibels
        commit()
    }

    /// Replaces the parametric-EQ pre-amp summand and re-pushes the composed total.
    public func setParametricPreamp(_ decibels: Float) {
        guard parametricPreampDB != decibels else { return }
        parametricPreampDB = decibels
        commit()
    }

    /// Replaces the head-room trim summand and re-pushes the composed total.
    public func setHeadroomTrim(_ decibels: Float) {
        guard headroomTrimDB != decibels else { return }
        headroomTrimDB = decibels
        commit()
    }

    /// The ONLY call to ``PlaybackEngine/setGlobalGain(_:)`` in the app. The
    /// engine re-clamps on receipt, which is idempotent here and keeps the
    /// safety bound defended in depth.
    private func commit() {
        engine?.setGlobalGain(composedGainDB)
    }
}

// MARK: - Attachment

public extension PlaybackEngine {
    /// The one ``GainComposer`` that owns this engine's global gain.
    ///
    /// Resolved by engine identity rather than injected, so every holder of the
    /// same engine — the ReplayGain service, the EQ view model, the head-room
    /// suggestion — reaches the same ledger without the composition root having
    /// to thread a fifth object through each of them. Two contributors that
    /// share an engine therefore cannot end up summing into different boxes.
    var gainComposer: GainComposer {
        GainComposerRegistry.composer(for: self)
    }
}

/// Identity-keyed storage for ``GainComposer`` instances.
///
/// Composers hold their engine weakly, so a released engine leaves a dead entry
/// behind. Dead entries are swept on every lookup — not housekeeping but
/// correctness: `ObjectIdentifier` is an address, and a new engine allocated
/// where a released one used to live would otherwise inherit its stale summands.
@MainActor
private enum GainComposerRegistry {
    private static var composers: [ObjectIdentifier: GainComposer] = [:]

    static func composer(for engine: any PlaybackEngine) -> GainComposer {
        composers = composers.filter(\.value.ownsLiveEngine)
        let key = ObjectIdentifier(engine)
        if let existing = composers[key] { return existing }
        let composer = GainComposer(engine: engine)
        composers[key] = composer
        return composer
    }
}

private extension GainComposer {
    /// `false` once the engine this composer was created for has been released.
    var ownsLiveEngine: Bool {
        engine != nil
    }
}
