// CrossfeedSettingsModel — the one place crossfeed preferences become engine state.
//
// Structurally `OutputRoutingModel`'s sibling: the pane binds to THIS rather than to
// `AppSettings`, because a crossfeed write is not a plain write. It has to persist AND
// reach `PlaybackEngine.setCrossfeed(enabled:fcut:feedDB:)`, and a binding straight to
// a settings store would do the first and neither of the others.
//
// ── EVERY TICK IS SAFE, SO THERE IS NO DEBOUNCE ─────────────────────────────
//
// Retuning an already-inserted stage does NOT re-wire the graph: the new coefficients
// ride the kernel's wait-free box and are adopted on the next render block. A slider
// drag can therefore call the seam on every tick without disturbing playback, and a
// debounce would only delay what the listener is dragging to hear. The equality guard
// below exists for the OTHER reason — `@Observable` fires on same-value writes, so an
// unchanged value must not spend a `UserDefaults` write and an engine call.
//
// ── NOTHING HERE CLAMPS ─────────────────────────────────────────────────────
//
// `CrossfeedLevel`'s initialiser clamps per component, so a stale preference yields a
// clamped stage rather than a failure, and `setCrossfeed` never throws. Re-checking
// here would be a second bound that could drift from the kernel's own.
//
// ── OFF IS THE SHIPPED DEFAULT, AND `start()` DOES NOT PERSIST ──────────────
//
// A fresh install reads `isEnabled == false` (absent ⇒ `bool(forKey:)` answers
// `false`). ``start()` pushes the stored state at launch and writes nothing back, the
// same discipline as `OutputRoutingModel.start(selectedUID:)`. Pushing a DISABLED
// state is inert by construction — the seam's disable path returns early when no node
// is installed — so the launch push is one code path, not two.
import AudioEngine
import DSP
import Foundation
import Observation

/// The crossfeed pane's state, and the seam it drives.
@MainActor
@Observable
final class CrossfeedSettingsModel {
    /// The listener's choices. Mutating this persists them and re-programmes the stage.
    var preferences: CrossfeedPreferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.persist(to: defaults)
            push()
        }
    }

    /// What the engine actually programmed, read back from the stage itself — `nil`
    /// when crossfeed is not in the signal path.
    ///
    /// Read back rather than mirrored, because the two can legitimately disagree: an
    /// out-of-range custom pair arrives clamped, and a stage that failed to install
    /// reports `nil` while the switch still says on.
    private(set) var programmedLevel: CrossfeedLevel?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let engine: @MainActor () -> (any PlaybackEngine)?

    init(
        defaults: UserDefaults = .standard,
        engine: @escaping @MainActor () -> (any PlaybackEngine)?
    ) {
        self.defaults = defaults
        self.engine = engine
        preferences = CrossfeedPreferences.load(from: defaults)
    }

    /// Adopts the stored preferences onto the engine at launch, without re-persisting.
    func start() {
        push()
    }

    private func push() {
        guard let engine = engine() else {
            programmedLevel = nil
            return
        }
        let level = preferences.resolvedLevel
        engine.setCrossfeed(
            enabled: preferences.isEnabled,
            fcut: level.cutFrequency,
            feedDB: level.feedDB
        )
        programmedLevel = engine.crossfeedLevel
    }
}
