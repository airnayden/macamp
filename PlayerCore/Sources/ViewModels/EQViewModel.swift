// EQViewModel — the 10-band graphic-EQ controller for the EQ UI.
//
// It mirrors ten band gains, applies built-in / custom presets by writing every
// band to the ``PlaybackEngine`` (and the preamp as the graphic summand of that
// engine's ``GainComposer``), persists custom presets through
// ``EQPresetStoring``, and tracks the selected ReplayGain mode (the app's
// ReplayGain service consumes it; the composed gain still lands on
// `eq.globalGain`, the ADR invariant).
//
// This file imports only AudioEngine + Foundation + Observation + Persistence +
// Services; it MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import AudioEngine
import Foundation
import Observation
import Persistence
import Services

/// Drives the ten-band EQ + preset selection over a ``PlaybackEngine``.
@MainActor
@Observable
public final class EQViewModel {
    /// Number of EQ bands (matches `EQBand.allCases`, 32 Hz … 16 kHz).
    public static let bandCount = 10

    /// Per-band gains in dB (index == `EQBand.rawValue`).
    public private(set) var bandGains: [Float]
    /// Built-in + persisted custom presets, in display order.
    public private(set) var presets: [EQPreset] = []
    /// The name of the applied preset, or `nil` after a manual band edit.
    public private(set) var selectedPresetName: String?
    /// Global pre-amp trim in dB (from the applied preset).
    public private(set) var preamp: Float = 0
    /// The selected ReplayGain mode.
    public private(set) var replayGainMode: ReplayGainMode = .off

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private let presetStore: any EQPresetStoring

    /// Creates an EQ view model.
    ///
    /// - Parameters:
    ///   - engine: The transport whose ten-band EQ receives the gains.
    ///   - presetStore: Persistence for user-created custom presets.
    public init(engine: any PlaybackEngine, presetStore: any EQPresetStoring) {
        self.engine = engine
        self.presetStore = presetStore
        bandGains = [Float](repeating: 0, count: Self.bandCount)
    }

    /// Loads built-in + persisted custom presets into ``presets``.
    public func loadPresets() {
        let custom = (try? presetStore.loadAll()) ?? []
        presets = EQPreset.builtIns + custom
    }
}

// MARK: - Band + preset application

public extension EQViewModel {
    /// Sets one band's gain on the engine and clears the preset selection.
    func setBandGain(_ index: Int, dB decibels: Float) {
        guard bandGains.indices.contains(index) else { return }
        bandGains[index] = decibels
        engine.setBandGain(index, dB: decibels)
        selectedPresetName = nil
    }

    /// Applies a preset: writes all ten band gains to the engine and the preset's
    /// preamp to the engine's gain composer, where it sums with ReplayGain rather
    /// than replacing it.
    func apply(_ preset: EQPreset) {
        let count = min(Self.bandCount, preset.bandGains.count)
        for index in 0 ..< count {
            let gain = preset.bandGains[index]
            bandGains[index] = gain
            engine.setBandGain(index, dB: gain)
        }
        preamp = preset.preamp ?? 0
        engine.gainComposer.setGraphicPreamp(preamp)
        selectedPresetName = preset.name
    }

    /// Applies a preset selected by name from ``presets``.
    func applyPreset(named name: String) {
        guard let preset = presets.first(where: { $0.name == name }) else { return }
        apply(preset)
    }

    /// Resets all bands to 0 dB (the Flat preset).
    func reset() {
        apply(.flat)
    }

    /// Selects the ReplayGain mode (applied by the app's ReplayGain service).
    func setReplayGainMode(_ mode: ReplayGainMode) {
        replayGainMode = mode
    }

    /// Persists the current band gains as a named custom preset.
    func saveCustomPreset(named name: String) throws {
        let preset = EQPreset(
            name: name,
            bandGains: bandGains,
            preamp: preamp == 0 ? nil : preamp
        )
        try presetStore.save(preset)
        loadPresets()
        selectedPresetName = name
    }
}
