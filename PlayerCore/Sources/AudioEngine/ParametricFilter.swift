// ParametricFilter — the value types behind MacAMP's parametric-EQ mode.
//
// The parametric EQ is a SECOND, independent mode beside the untouched ten-band
// graphic equaliser (`EQBand`). Where the graphic EQ is a fixed ISO layout with
// only per-band gains, a parametric configuration is a variable-length list of
// fully specified filters (type, centre frequency, gain, Q) plus a global
// pre-amp — the shape AutoEq and every other headphone-correction project emits.
//
// These types are pure data: no AVFAudio object is created here and nothing is
// applied to a graph. Todo 19 owns the engine seam that pushes a configuration
// onto a second `AVAudioUnitEQ`; todo 20 owns persistence; todo 21 owns the UI.
//
// This file imports only AVFAudio + Foundation; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import AVFAudio
import Foundation

// MARK: - Filter type

/// The three filter shapes an AutoEq `ParametricEQ.txt` profile can specify.
///
/// The raw values are the exact tokens AutoEq writes, and they are a **wire
/// format** — a profile file, a persisted preset (todo 20), and the import UI
/// (todo 21) all round-trip through them, so they must never be renamed.
///
/// AutoEq emits `LSC`/`HSC` ("low/high shelf, corner-frequency parameterised"),
/// **not** the legacy `LS`/`HS` tokens older exporters used. The parser rejects
/// `LS`/`HS` outright rather than guessing, because the two spellings disagree
/// about whether `Fc` is the corner or the mid-point frequency.
public enum ParametricFilterType: String, Codable, Sendable, CaseIterable, Hashable {
    /// Peaking (bell) filter — AutoEq token `PK`.
    case peaking = "PK"
    /// Low shelf, corner-frequency parameterised — AutoEq token `LSC`.
    case lowShelf = "LSC"
    /// High shelf, corner-frequency parameterised — AutoEq token `HSC`.
    case highShelf = "HSC"

    /// Whether this shape is a shelving filter (and therefore subject to the
    /// documented `AVAudioUnitEQ` slope limitation — see
    /// ``ParametricFilter/isShelfSlopeApproximated``).
    public var isShelf: Bool {
        switch self {
        case .peaking: false
        case .lowShelf, .highShelf: true
        }
    }

    /// The `AVAudioUnitEQ` filter type this shape maps onto.
    ///
    /// - Important: `.lowShelf` / `.highShelf` **ignore** the `bandwidth`
    ///   parameter (see ``ParametricFilter/isShelfSlopeApproximated``). Only
    ///   `.parametric` honours the Q → bandwidth conversion.
    public var avFilterType: AVAudioUnitEQFilterType {
        switch self {
        case .peaking: .parametric
        case .lowShelf: .lowShelf
        case .highShelf: .highShelf
        }
    }
}

// MARK: - Single filter

/// One fully specified parametric-EQ band: shape, centre frequency, gain, and Q.
///
/// Stored in `Double` rather than `Float` so a profile survives a JSON
/// round-trip (todo 20) bit-for-bit and so the RBJ reference evaluation
/// (``RBJBiquad``) is not limited by the AU's single-precision parameters.
/// Conversion to `Float` happens only at the `AVAudioUnitEQ` boundary.
public struct ParametricFilter: Codable, Sendable, Equatable, Hashable {
    /// The filter shape (`PK` / `LSC` / `HSC`).
    public var type: ParametricFilterType
    /// Centre (peaking) or corner (shelving) frequency in Hz.
    public var frequency: Double
    /// Gain in dB. Positive boosts, negative cuts.
    public var gainDB: Double
    /// Quality factor. Higher Q is a narrower peak / steeper shelf.
    public var qFactor: Double

    public init(type: ParametricFilterType, frequency: Double, gainDB: Double, qFactor: Double) {
        self.type = type
        self.frequency = frequency
        self.gainDB = gainDB
        self.qFactor = qFactor
    }
}

// MARK: - AVAudioUnitEQ parameter ranges

/// The legal parameter ranges of `AVAudioUnitEQFilterParameters`, transcribed
/// from the AVFAudio SDK header (`AVAudioUnitEQ.h`).
///
/// These are the AU's own documented bounds, not MacAMP policy: a value outside
/// them is undefined behaviour at the AU, so every configuration is clamped into
/// them on the way in (todo 19) rather than being rejected on the way in from a
/// profile file — a real AutoEq profile with `Q 5.75` is perfectly valid music
/// data even though the AU cannot express its exact bandwidth.
public enum ParametricEQLimits {
    /// `frequency`: 20 Hz → Nyquist. The upper bound is sample-rate dependent,
    /// so only the fixed lower bound lives here.
    public static let minimumFrequency: Double = 20
    /// `bandwidth`: 0.05 → 5.0 octaves.
    public static let bandwidthRange: ClosedRange<Double> = 0.05 ... 5.0
    /// `gain`: −96 → +24 dB (the same range as `AVAudioUnitEQ.globalGain`).
    public static let gainRange: ClosedRange<Double> = -96 ... 24
}

// MARK: - Q → bandwidth

public extension ParametricFilter {
    /// The filter's bandwidth in **octaves**, the parameterisation
    /// `AVAudioUnitEQFilterParameters.bandwidth` expects.
    ///
    /// AutoEq (like every RBJ-cookbook implementation) specifies Q; the AU wants
    /// octaves. The two are related through the cookbook's own
    /// `1/Q = 2·sinh(ln2/2 · BW)` definition, inverted:
    ///
    /// ```
    /// BW = 2·asinh(1/(2Q)) / ln2
    /// ```
    ///
    /// which is algebraically identical to the closed form
    /// `BW = ln(1 + 1/(2Q²) + √(((2Q²+1)/Q²)²/4 − 1)) / ln2` — the two differ by
    /// the `cosh(2y) = 1 + 2sinh²(y)` double-angle identity and agree to machine
    /// precision. The `asinh` form is used here because it stays
    /// well-conditioned as Q grows, where the closed form's `√(u² − 1)` loses
    /// significance against `u → 1`.
    ///
    /// The value is **unclamped** — see ``auBandwidth`` for the AU-legal value.
    var bandwidthInOctaves: Double {
        guard qFactor > 0 else { return ParametricEQLimits.bandwidthRange.upperBound }
        return 2 * asinh(1 / (2 * qFactor)) / log(2)
    }

    /// ``bandwidthInOctaves`` clamped into the AU's legal `0.05 … 5.0` octave
    /// range and narrowed to `Float`, ready to assign to
    /// `AVAudioUnitEQFilterParameters.bandwidth`.
    ///
    /// - Important: the AU **ignores** this value for `.lowShelf` / `.highShelf`
    ///   bands. See ``isShelfSlopeApproximated``.
    var auBandwidth: Float {
        let range = ParametricEQLimits.bandwidthRange
        return Float(min(max(bandwidthInOctaves, range.lowerBound), range.upperBound))
    }

    /// ``gainDB`` clamped into the AU's legal `−96 … +24 dB` range, as `Float`.
    var auGain: Float {
        let range = ParametricEQLimits.gainRange
        return Float(min(max(gainDB, range.lowerBound), range.upperBound))
    }
}

// MARK: - Documented shelf-slope limitation

public extension ParametricFilter {
    /// The shelf Q that `AVAudioUnitEQ`'s fixed shelf slope is assumed to
    /// correspond to, and the Q AutoEq itself emits for essentially every shelf
    /// it generates (`Q 0.70` / `Q 0.71`).
    static let referenceShelfQ: Double = 0.71

    /// The relative tolerance around ``referenceShelfQ`` inside which an
    /// imported shelf is considered faithfully reproduced (±20%, i.e.
    /// `0.568 … 0.852`).
    static let shelfQTolerance: Double = 0.20

    /// Whether this filter's slope will only be **approximated** by
    /// `AVAudioUnitEQ`.
    ///
    /// **Documented limitation (verified against the AVFAudio SDK header,
    /// `AVAudioUnitEQ.h`).** The header lists the required parameters per filter
    /// type:
    ///
    /// - `AVAudioUnitEQFilterTypeParametric` — *frequency (center), bandwidth, gain*
    /// - `AVAudioUnitEQFilterTypeBandPass` / `…BandStop` — *frequency (center), bandwidth*
    /// - `AVAudioUnitEQFilterTypeLowShelf` — *frequency (center), **gain*** — no bandwidth
    /// - `AVAudioUnitEQFilterTypeHighShelf` — *frequency (center), **gain*** — no bandwidth
    ///
    /// `bandwidth` therefore applies only to `.parametric` / `.bandPass` /
    /// `.bandStop`. The two shelf types consume frequency and gain alone and
    /// render at Apple's own fixed, undocumented slope, so an imported `LSC`/`HSC`
    /// Q is honoured only approximately.
    ///
    /// (`AVAudioUnitEQFilterTypeResonantLowShelf` / `…ResonantHighShelf` *do*
    /// take bandwidth, but they are resonant shelves — a different magnitude
    /// response with a corner peak — so substituting them would change the curve
    /// rather than fix the slope. MacAMP maps `LSC`/`HSC` onto the plain shelves
    /// and surfaces this flag instead.)
    ///
    /// `true` when the filter is a shelf **and** its Q deviates from
    /// ``referenceShelfQ`` by more than ``shelfQTolerance``. The import UI
    /// (todo 21) reads this to surface an "approximated shelf slope" notice;
    /// todo 19 carries the matching render-tolerance acceptance case.
    var isShelfSlopeApproximated: Bool {
        guard type.isShelf else { return false }
        let reference = Self.referenceShelfQ
        return abs(qFactor - reference) / reference > Self.shelfQTolerance
    }
}

// MARK: - Configuration

/// A complete parametric-EQ profile: an ordered list of filters plus the global
/// pre-amp trim that keeps their combined boost from clipping.
///
/// The pre-amp is carried here as data only. It is **never** written to this
/// node's `globalGain` (nor the graphic EQ's) — it routes through the shared
/// gain composer (todo 3) alongside ReplayGain and the headroom trim, so the
/// three cannot silently overwrite each other.
public struct ParametricEQConfiguration: Codable, Sendable, Equatable, Hashable {
    /// The filters, in profile order. Order is cosmetic for the magnitude
    /// response (the filters are in series) but is preserved so a round-trip
    /// through persistence or the editor is stable.
    public var filters: [ParametricFilter]
    /// Global pre-amp trim in dB, typically negative to make headroom for the
    /// filters' combined boost.
    public var preampDB: Double

    public init(filters: [ParametricFilter] = [], preampDB: Double = 0) {
        self.filters = filters
        self.preampDB = preampDB
    }

    /// The number of bands the parametric `AVAudioUnitEQ` node is created with
    /// (todo 19), and therefore the ceiling the parser and the editor (todo 21)
    /// enforce. Unused bands are bypassed rather than removed.
    public static let maximumFilterCount = 16

    /// An empty configuration — no filters, no pre-amp. Equivalent to bypass.
    ///
    /// Deliberately **not** named `none`: todo 19's seam is
    /// `setParametricConfiguration(_:)` taking an `Optional`, where `.none`
    /// would silently resolve to `Optional.none` instead of this value.
    public static let bypass = ParametricEQConfiguration()

    /// Whether this configuration has no audible effect.
    public var isEmpty: Bool {
        filters.isEmpty && preampDB == 0
    }
}

public extension ParametricEQConfiguration {
    /// The offsets of every filter whose shelf slope `AVAudioUnitEQ` can only
    /// approximate — see ``ParametricFilter/isShelfSlopeApproximated``.
    ///
    /// Computed rather than captured at parse time so it stays correct after the
    /// user edits a Q in the parametric editor (todo 21).
    var approximatedShelfFilterIndices: [Int] {
        filters.indices.filter { filters[$0].isShelfSlopeApproximated }
    }

    /// Whether any filter's shelf slope will only be approximated. The import UI
    /// (todo 21) gates its localized "approximated shelf slope" notice on this.
    var hasApproximatedShelfSlope: Bool {
        filters.contains(where: \.isShelfSlopeApproximated)
    }
}
