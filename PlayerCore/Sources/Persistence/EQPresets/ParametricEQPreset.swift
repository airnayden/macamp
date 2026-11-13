import Foundation

// ParametricEQPreset — a named parametric-EQ filter bank for MacAMP.
//
// This is the parametric counterpart of `EQPreset`, stored in the separate `v19`
// `parametricEQPreset` table. The v3 `eqPreset` table and the 10-band graphic
// contract it enforces are untouched by this type.
//
// The filter bank travels as JSON text rather than as a typed array because the
// filter type — `AudioEngine.ParametricFilter` — lives in a module `Persistence`
// must not import (it would drag `AVFAudio` and `SFBAudioEngine` behind it). This
// is the same boundary discipline that keeps `BlockLoudnessHistogram` taking
// `[Double]` rather than a `Services.LoudnessMeasurement`.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).

/// A named parametric-EQ preset: a JSON-encoded filter bank plus a pre-amp trim.
///
/// `filtersJson` is a JSON **array** of `AudioEngine.ParametricFilter` values in
/// profile order. `Persistence` stores and returns it verbatim; decoding it into
/// typed filters is the caller's step, through ``filters(as:)``. That split is what
/// lets one unreadable row fail on its own without poisoning a whole
/// ``ParametricEQPresetStoring/loadAll()``.
public struct ParametricEQPreset: Codable, Sendable, Equatable, Hashable {
    /// Display name. Unique across the store — a same-name ``save`` replaces.
    public var name: String

    /// JSON array of `AudioEngine.ParametricFilter` values, in profile order.
    public var filtersJson: String

    /// Optional global pre-amp trim in dB, typically negative to make headroom for
    /// the bank's combined boost. `nil` means no trim was recorded, which is not the
    /// same as a stored `0` ("measured, and it is unity").
    public var preamp: Double?

    public init(name: String, filtersJson: String, preamp: Double? = nil) {
        self.name = name
        self.filtersJson = filtersJson
        self.preamp = preamp
    }
}

// MARK: - Typed filter bridging

public extension ParametricEQPreset {
    /// Creates a preset by JSON-encoding a typed filter bank.
    ///
    /// The element type is generic so `Persistence` never names
    /// `AudioEngine.ParametricFilter`; callers pass `[ParametricFilter]` directly.
    ///
    /// - Throws: `EncodingError` if the filters cannot be JSON-encoded.
    init(name: String, filters: [some Encodable], preamp: Double? = nil) throws {
        let data = try JSONEncoder().encode(filters)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                filters,
                .init(codingPath: [], debugDescription: "filters JSON encoding produced non-UTF8 data")
            )
        }
        self.init(name: name, filtersJson: json, preamp: preamp)
    }

    /// Decodes ``filtersJson`` into a typed filter bank.
    ///
    /// - Throws: `DecodingError` if the stored text is not valid UTF-8 or does not
    ///   decode as an array of `Filter`. The failure is scoped to this preset — the
    ///   store never decodes on behalf of the caller, so a corrupted row cannot make
    ///   its siblings unreadable.
    func filters<Filter: Decodable>(as _: Filter.Type) throws -> [Filter] {
        guard let data = filtersJson.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "filtersJson is not valid UTF-8")
            )
        }
        return try JSONDecoder().decode([Filter].self, from: data)
    }
}
