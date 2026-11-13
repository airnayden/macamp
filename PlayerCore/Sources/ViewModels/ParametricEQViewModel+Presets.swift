// ParametricEQViewModel+Presets — AutoEq import and the saved-preset bank.
//
// Split from `ParametricEQViewModel.swift` so both halves stay inside SwiftLint's
// `file_length` budget, following the module's existing `+`-suffixed extension
// pattern (`SignalPathModel+Text.swift`, `FolderOutlineViewModel+Rows.swift`).
//
// This file imports only AudioEngine + Foundation + Persistence; it MUST NOT
// import AppKit or UIKit (PlayerCore portability invariant).
import AudioEngine
import Foundation
import Persistence

// MARK: - AutoEq import

public extension ParametricEQViewModel {
    /// Parses an AutoEq profile from `url` and installs it.
    ///
    /// A successful import ACTIVATES ``EqualizerMode/parametric`` — a listener who
    /// picked a headphone correction expects to hear it — and clears the preset
    /// selection, because the bank no longer belongs to a saved preset.
    ///
    /// Every failure path leaves the bank, the trim, the mode and the engine
    /// EXACTLY as they were; the only observable change is ``lastFailure``. The two
    /// failures are kept apart on purpose: a file MacAMP could not read is a
    /// different problem for the listener than a file that is not an AutoEq
    /// profile, and only the second one can name a line number.
    func importProfile(from url: URL) {
        let parsed: ParametricEQConfiguration
        do {
            parsed = try AutoEqProfileParser.parse(contentsOf: url)
        } catch let error as AutoEqParseError {
            lastFailure = .profileInvalid(error)
            return
        } catch {
            lastFailure = .profileUnreadable(fileName: url.lastPathComponent)
            return
        }
        guard commit(parsed, mode: .parametric) else { return }
        selectedPresetName = nil
        lastImportedProfileName = url.deletingPathExtension().lastPathComponent
        lastFailure = nil
    }
}

// MARK: - Presets

public extension ParametricEQViewModel {
    /// Reloads ``presets`` from the store.
    ///
    /// The store never decodes `filtersJson`, so the decode happens here, ONE ROW
    /// AT A TIME: a row whose JSON is unreadable comes back with
    /// ``ParametricPresetRow/isReadable`` `false` and stays in the list, which is
    /// what makes "one corrupt preset cannot empty the preset list" a property of
    /// the shape rather than of a `try?` somewhere.
    func loadPresets() {
        let stored = (try? presetStore.loadAll()) ?? []
        presets = stored.map { preset in
            ParametricPresetRow(
                preset: preset,
                filters: try? preset.filters(as: ParametricFilter.self)
            )
        }
    }

    /// Applies the named preset, activating ``EqualizerMode/parametric``.
    ///
    /// An unreadable row is refused with ``ParametricEQFailure/presetUnreadable(name:)``
    /// and an over-capacity one with ``ParametricEQFailure/capacityExceeded(count:maximum:)``
    /// — the second is reachable only from a hand-authored row, since neither the
    /// editor nor the profile parser can produce one, and it is caught by
    /// ``commit(_:mode:)``'s capacity check BEFORE the engine is touched.
    func applyPreset(named name: String) {
        guard let row = presets.first(where: { $0.name == name }) else { return }
        guard let configuration = row.configuration else {
            lastFailure = .presetUnreadable(name: name)
            return
        }
        guard commit(configuration, mode: .parametric) else { return }
        selectedPresetName = name
        lastFailure = nil
    }

    /// Persists the current bank under `name`, replacing any preset of that name.
    ///
    /// A zero trim is stored as `nil` ("no trim recorded"), matching
    /// ``EQViewModel/saveCustomPreset(named:)`` and the nullable `preamp` column.
    func savePreset(named name: String) {
        do {
            let preset = try ParametricEQPreset(
                name: name,
                filters: filters,
                preamp: preampDB == 0 ? nil : preampDB
            )
            try presetStore.save(preset)
        } catch {
            lastFailure = .presetWriteFailed(name: name)
            return
        }
        loadPresets()
        selectedPresetName = name
        lastFailure = nil
    }

    /// Deletes the named preset. The live bank is left alone — deleting the recipe
    /// is not the same as undoing the dish.
    func deletePreset(named name: String) {
        do {
            try presetStore.delete(named: name)
        } catch {
            lastFailure = .presetWriteFailed(name: name)
            return
        }
        if selectedPresetName == name { selectedPresetName = nil }
        loadPresets()
    }
}
