// ParametricEQModels — the value types the parametric-EQ editor is built from.
//
// Split out of `ParametricEQViewModel.swift` so the view model file stays inside
// SwiftLint's `file_length` budget and so a shell can name the mode, the failure
// and a preset row without importing the whole controller.
//
// These types hold **data, not prose**: every failure case carries the numbers and
// names a shell needs to build localized copy, and none of them carries an English
// sentence. PlayerCore holds no user-facing text (String Catalogs live in the
// shells), which is the same discipline `AutoEqParseError` and
// `ParametricEQConfigurationError` already follow.
//
// This file imports only AudioEngine + Foundation + Persistence; it MUST NOT
// import AppKit or UIKit (PlayerCore portability invariant).
import AudioEngine
import Foundation
import Persistence

// MARK: - Mode

/// Which equalizer drives the playback graph.
///
/// The two are independent nodes in different ``ProcessingSlot``s, so this is a
/// UI-level choice rather than an engine-level exclusion: selecting ``graphic``
/// DETACHES the parametric stage (``PlaybackEngine/setParametricConfiguration(_:)``
/// with `nil`), and the ten graphic band gains are left exactly as the user set
/// them. Nothing here reads or writes the graphic EQ's bands or presets.
public enum EqualizerMode: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    /// The shipped ten-band graphic EQ (``EQViewModel``).
    case graphic
    /// The AutoEq-style parametric filter bank (``ParametricEQViewModel``).
    case parametric

    public var id: String {
        rawValue
    }
}

// MARK: - Failure

/// Everything the parametric editor can refuse to do.
///
/// Cases carry **data, not prose**. A shell maps each onto a String Catalog entry;
/// ``profileInvalid(_:)`` wraps ``AutoEqParseError`` whole precisely so the message
/// can name the offending line through ``AutoEqParseError/lineNumber``.
///
/// `Equatable` but deliberately **not** `Hashable`: ``AutoEqParseError`` is only
/// `Equatable`, and synthesising a hash would mean restating its payload here.
public enum ParametricEQFailure: Error, Sendable, Equatable {
    /// The chosen file could not be read at all (missing, unreadable, not UTF-8).
    case profileUnreadable(fileName: String)
    /// The file was read but is not a valid AutoEq profile.
    case profileInvalid(AutoEqParseError)
    /// More filters than the parametric node has bands.
    ///
    /// Reachable two ways: adding past the ceiling in the editor (refused before
    /// the engine is touched) and applying a stored preset whose `filtersJson`
    /// carries more filters than ``ParametricEQConfiguration/maximumFilterCount``.
    case capacityExceeded(count: Int, maximum: Int)
    /// A saved preset's `filtersJson` did not decode. The row stays in the list
    /// with an "unreadable" badge and a delete affordance — it is never dropped.
    case presetUnreadable(name: String)
    /// A preset could not be written to (or deleted from) the store.
    case presetWriteFailed(name: String)
    /// The engine refused the configuration for a reason the seam did not name.
    case engineRefused
}

// MARK: - Preset row

/// One row of the saved-preset list, with its filter bank decoded **eagerly but
/// individually**.
///
/// ``ParametricEQPresetStoring/loadAll()`` never decodes `filtersJson`, so one
/// corrupt row cannot empty the preset list. This type preserves that property at
/// the presentation layer: the decode is attempted per row, and a row that fails
/// still renders (``isReadable`` is `false`) and is still deletable by name.
public struct ParametricPresetRow: Identifiable, Sendable, Equatable, Hashable {
    /// The stored preset, verbatim.
    public let preset: ParametricEQPreset
    /// The decoded filter bank, or `nil` when `filtersJson` could not be decoded.
    public let filters: [ParametricFilter]?

    public init(preset: ParametricEQPreset, filters: [ParametricFilter]?) {
        self.preset = preset
        self.filters = filters
    }

    /// Preset names are unique across the store, so the name IS the identity.
    public var id: String {
        preset.name
    }

    public var name: String {
        preset.name
    }

    /// Whether this row's filter bank decoded. A `false` row must render with an
    /// "unreadable" badge rather than being hidden.
    public var isReadable: Bool {
        filters != nil
    }

    /// The number of filters in the bank, or `0` when unreadable.
    public var filterCount: Int {
        filters?.count ?? 0
    }

    /// The stored pre-amp trim in dB.
    ///
    /// A `nil` column means "no trim recorded", which is **not** the same as a
    /// stored `0` ("measured, and it is unity") — but a configuration needs a
    /// number, so the boundary maps `nil` to `0` exactly here and nowhere else.
    public var preampDB: Double {
        preset.preamp ?? 0
    }

    /// The configuration this row applies, or `nil` when the row is unreadable.
    public var configuration: ParametricEQConfiguration? {
        filters.map { ParametricEQConfiguration(filters: $0, preampDB: preampDB) }
    }
}
