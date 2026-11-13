// ParametricEQViewModel — the parametric-EQ editor's controller.
//
// The parametric counterpart of ``EQViewModel``. It owns the filter bank, the
// pre-amp trim, the saved-preset list and the Graphic/Parametric mode selection,
// and it is the ONE place that pushes a configuration to
// ``PlaybackEngine/setParametricConfiguration(_:)``.
//
// It never touches the graphic EQ. The two equalizers are independent nodes in
// different processing slots: selecting ``EqualizerMode/graphic`` DETACHES the
// parametric stage rather than zeroing anything, and the ten graphic band gains,
// their presets and their pre-amp are left exactly as ``EQViewModel`` last set
// them.
//
// THE PRE-AMP NEVER LANDS ON A NODE. `ParametricEQConfiguration.preampDB` travels
// with the configuration and the ENGINE SEAM routes it to
// `GainComposer.setParametricPreamp(_:)`, where it sums with ReplayGain, the
// graphic pre-amp and the head-room trim. That is why this model pushes the whole
// configuration and never writes a gain itself: forgetting an imported profile's
// `Preamp:` line is exactly how an AutoEq import clips.
//
// This file imports only AudioEngine + Foundation + Observation + Persistence; it
// MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import AudioEngine
import Foundation
import Observation
import Persistence

/// Drives the parametric filter bank + preset selection over a ``PlaybackEngine``.
@MainActor
@Observable
public final class ParametricEQViewModel {
    /// The parametric node's band count — the ceiling the editor, the profile
    /// parser and the engine all enforce from the same constant.
    public static let maximumFilterCount = ParametricEQConfiguration.maximumFilterCount

    /// The shape a newly added band starts at: a neutral 1 kHz bell.
    ///
    /// Neutral on purpose — adding a band must never change what the listener
    /// hears until they move a control.
    public static let defaultFilter = ParametricFilter(
        type: .peaking,
        frequency: 1000,
        gainDB: 0,
        qFactor: 1.0
    )

    /// Which equalizer is driving the graph. Defaults to ``EqualizerMode/graphic``
    /// so a launch behaves exactly as it did before this editor existed.
    public private(set) var mode: EqualizerMode = .graphic
    /// The filter bank, in profile order.
    public private(set) var filters: [ParametricFilter] = []
    /// The global pre-amp trim in dB (routed to the gain composer by the engine).
    public private(set) var preampDB: Double = 0
    /// Persisted presets, ordered by name, including unreadable ones.
    ///
    /// The four properties below are `internal(set)` rather than `private(set)`
    /// only because `ParametricEQViewModel+Presets.swift` writes them; nothing
    /// outside this module can set them.
    public internal(set) var presets: [ParametricPresetRow] = []
    /// The name of the applied preset, or `nil` after a manual edit or an import.
    public internal(set) var selectedPresetName: String?
    /// The most recent refusal, or `nil`. Cleared by ``clearFailure()``.
    public internal(set) var lastFailure: ParametricEQFailure?
    /// The base name of the last successfully imported profile — the shell's
    /// suggested preset name after an AutoEq import.
    public internal(set) var lastImportedProfileName: String?

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored let presetStore: any ParametricEQPresetStoring

    /// Creates a parametric-EQ view model.
    ///
    /// - Parameters:
    ///   - engine: The transport whose parametric stage receives the configuration.
    ///   - presetStore: Persistence for user-authored parametric presets.
    public init(engine: any PlaybackEngine, presetStore: any ParametricEQPresetStoring) {
        self.engine = engine
        self.presetStore = presetStore
    }
}

// MARK: - Derived state

public extension ParametricEQViewModel {
    /// The current bank and trim as one value — what a commit pushes and what a
    /// save persists.
    var configuration: ParametricEQConfiguration {
        ParametricEQConfiguration(filters: filters, preampDB: preampDB)
    }

    /// Whether the parametric stage is the one in the graph.
    var isParametricActive: Bool {
        mode == .parametric
    }

    /// Whether another band can be added without exceeding the node's capacity.
    var canAddFilter: Bool {
        filters.count < Self.maximumFilterCount
    }

    /// The offsets of every band whose shelf slope `AVAudioUnitEQ` can only
    /// approximate — the shell gates its "approximated shelf slope" notice on
    /// these. Recomputed from the live bank, so editing a Q updates it.
    var approximatedShelfFilterIndices: [Int] {
        configuration.approximatedShelfFilterIndices
    }

    /// Whether any band's shelf slope will only be approximated.
    var hasApproximatedShelfSlope: Bool {
        configuration.hasApproximatedShelfSlope
    }
}

// MARK: - Mode + band editing

public extension ParametricEQViewModel {
    /// Selects the active equalizer.
    ///
    /// Switching to ``EqualizerMode/graphic`` pushes `nil`, which **detaches** the
    /// parametric node rather than bypassing sixteen bands — that is what makes
    /// the graph bit-identical to one that never had the stage. A refused switch
    /// leaves ``mode`` untouched.
    func setMode(_ newMode: EqualizerMode) {
        guard newMode != mode else { return }
        commit(configuration, mode: newMode)
    }

    /// Appends a band, refusing at the node's capacity.
    ///
    /// The refusal happens here, BEFORE the engine is touched, so the editor can
    /// never present the seam with a seventeenth filter. The engine's own
    /// `validateFilterCapacity()` still guards the preset path — see
    /// ``applyPreset(named:)``.
    func addFilter(_ filter: ParametricFilter = ParametricEQViewModel.defaultFilter) {
        guard canAddFilter else {
            lastFailure = .capacityExceeded(
                count: filters.count + 1,
                maximum: Self.maximumFilterCount
            )
            return
        }
        edit(filters + [filter], preampDB: preampDB)
    }

    /// Removes the band at `index`. Out-of-range indices are ignored.
    func removeFilter(at index: Int) {
        guard filters.indices.contains(index) else { return }
        var next = filters
        next.remove(at: index)
        edit(next, preampDB: preampDB)
    }

    /// Replaces the band at `index`. A write of the same value is a no-op, so a
    /// SwiftUI binding re-writing its current value never re-pushes the graph.
    func setFilter(_ filter: ParametricFilter, at index: Int) {
        guard filters.indices.contains(index), filters[index] != filter else { return }
        var next = filters
        next[index] = filter
        edit(next, preampDB: preampDB)
    }

    /// Sets the global pre-amp trim in dB.
    func setPreamp(_ decibels: Double) {
        guard decibels != preampDB else { return }
        edit(filters, preampDB: decibels)
    }

    /// Clears the bank and the trim, leaving the mode alone.
    func reset() {
        edit([], preampDB: 0)
    }

    /// Dismisses ``lastFailure``.
    func clearFailure() {
        lastFailure = nil
    }
}

// MARK: - Commit

extension ParametricEQViewModel {
    /// Applies an edited bank: commits it and clears the preset selection, since
    /// the bank no longer matches the preset it came from.
    private func edit(_ newFilters: [ParametricFilter], preampDB decibels: Double) {
        let next = ParametricEQConfiguration(filters: newFilters, preampDB: decibels)
        guard commit(next) else { return }
        selectedPresetName = nil
    }

    /// The single path from this model to the engine.
    ///
    /// Mirrors the engine seam's own ordering: **validate, push, THEN mutate**, so
    /// a refused configuration leaves `mode`, `filters` and `preampDB` exactly as
    /// they were and the failure is the only observable change.
    ///
    /// The push is skipped entirely while the resolved mode is
    /// ``EqualizerMode/graphic`` and the mode is not changing — there is no
    /// parametric node installed to reprogram, and pushing `nil` on every
    /// keystroke would be pure noise.
    ///
    /// - Returns: `true` when the configuration was accepted.
    @discardableResult
    func commit(
        _ configuration: ParametricEQConfiguration,
        mode targetMode: EqualizerMode? = nil
    ) -> Bool {
        let resolved = targetMode ?? mode
        do {
            try configuration.validateFilterCapacity()
            if resolved == .parametric {
                try engine.setParametricConfiguration(configuration)
            } else if resolved != mode {
                try engine.setParametricConfiguration(nil)
            }
        } catch let error as ParametricEQConfigurationError {
            lastFailure = Self.failure(for: error)
            return false
        } catch {
            lastFailure = .engineRefused
            return false
        }
        mode = resolved
        filters = configuration.filters
        preampDB = configuration.preampDB
        return true
    }

    private static func failure(for error: ParametricEQConfigurationError) -> ParametricEQFailure {
        switch error {
        case let .tooManyFilters(count, maximum):
            .capacityExceeded(count: count, maximum: maximum)
        }
    }
}
