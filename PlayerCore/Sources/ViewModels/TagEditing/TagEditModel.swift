// TagEditModel — the PURE, side-effect-free core of the tag editor.
//
// Shared verbatim by the macOS and iOS shells (each owns its own `TagEditorViewModel`
// and platform view code; this model is the portable logic they have in common). It
// owns the editor's data model and the two pieces of logic that must be correct
// regardless of any UI or filesystem:
//
//   1. Batch mixed-value collapse: given the same field across N selected tracks,
//      decide whether they share one value (show it) or disagree (show a
//      "(Multiple Values)" placeholder).
//   2. Dirty-only patch diff: build a ``WritableMetadata`` that carries ONLY the
//      fields the user actually edited, leaving every untouched field `nil`
//      (= unchanged) so a partial edit never clobbers a tag the user did not
//      touch — and, in batch, so only changed fields are written across all
//      tracks.
//
// Both are also exercised by ``TagFormSelfCheck`` and its `#Preview` in each shell's
// tag-editor sheet (an eyeballable canvas self-check), in addition to the package
// unit tests (`TagEditModelTests`).
//
// AppKit/UIKit-free: imports only Foundation + the PlayerCore Metadata + the
// Persistence record types it maps from/to.
import Foundation
import Metadata
import Persistence

// MARK: - TagField

/// One editable scalar tag field. Artwork is modelled separately (it is
/// tri-state, not a string).
public enum TagField: String, CaseIterable, Sendable {
    case title
    case artist
    case album
    case albumArtist
    case genre
    case composer
    case year
    case trackNumber
    case discNumber

    /// `true` for fields parsed as an integer (year, track #, disc #).
    public var isNumeric: Bool {
        switch self {
        case .year, .trackNumber, .discNumber: true
        default: false
        }
    }

    /// `true` for fields that exist as a column on ``TrackRecord`` (so a batch can
    /// derive a common/mixed value without reading every file). The rest
    /// (albumArtist, composer, year) live only in the file's tags.
    public var isDatabaseBacked: Bool {
        switch self {
        case .albumArtist, .composer, .year: false
        default: true
        }
    }
}

// MARK: - TagFieldState

/// The editable state of one field: its current text, whether it started as a
/// batch "mixed" placeholder, and whether the user has edited it.
public struct TagFieldState: Equatable, Sendable {
    /// The text currently shown in the field.
    public var text: String
    /// `true` when the selected tracks disagreed on this field at load time, so
    /// the field renders a "(Multiple Values)" placeholder until edited.
    public var isMixed: Bool
    /// `true` once the user has typed into the field; only dirty fields are written.
    public var isDirty: Bool

    /// A field pre-filled with a single shared value.
    public static func common(_ text: String) -> TagFieldState {
        TagFieldState(text: text, isMixed: false, isDirty: false)
    }

    /// A field whose tracks disagreed: empty, placeholdered, not dirty.
    public static let mixed = TagFieldState(text: "", isMixed: true, isDirty: false)
}

// MARK: - ArtworkEdit

/// The tri-state artwork intent, mirroring ``WritableMetadata/artwork`` semantics.
public enum ArtworkEdit: Equatable, Sendable {
    /// Leave the file's existing pictures untouched.
    case unchanged
    /// Remove every embedded picture (`WritableMetadata.artwork = []`).
    case remove
    /// Replace all pictures with this one image.
    case replace(data: Data, mimeType: String?)
}

// MARK: - TagFormModel

/// The whole editor form: every field's state plus the artwork intent. Pure value
/// type so the view model can mutate it and the self-check can assert on it.
public struct TagFormModel: Equatable, Sendable {
    public var fields: [TagField: TagFieldState]
    public var artwork: ArtworkEdit

    public init(fields: [TagField: TagFieldState], artwork: ArtworkEdit = .unchanged) {
        self.fields = fields
        self.artwork = artwork
    }

    /// `true` when at least one field is dirty or artwork changed — drives whether
    /// the Save button is enabled and whether a patch would do anything.
    public var hasChanges: Bool {
        if artwork != .unchanged { return true }
        return fields.values.contains { $0.isDirty }
    }

    /// Records an edit: marks the field dirty and clears any "mixed" placeholder
    /// (once typed, the field holds a concrete value to write to every track).
    public mutating func setField(_ field: TagField, to text: String) {
        var state = fields[field] ?? .common("")
        state.text = text
        state.isDirty = true
        state.isMixed = false
        fields[field] = state
    }

    /// Sets the artwork intent (replace / remove / unchanged).
    public mutating func setArtwork(_ edit: ArtworkEdit) {
        artwork = edit
    }
}

// MARK: - Building the form

public extension TagFormModel {
    /// Builds the form for a SINGLE track. `fileMetadata` (read from disk) is the
    /// authoritative source when available — it carries albumArtist / composer /
    /// year / artwork, which ``TrackRecord`` does not store. When the file could
    /// not be read (read-only source), the DB columns pre-fill what they can.
    static func single(record: TrackRecord, fileMetadata: TrackMetadata?) -> TagFormModel {
        let meta = fileMetadata
        var fields: [TagField: TagFieldState] = [:]
        fields[.title] = .common(meta?.title ?? record.title ?? "")
        fields[.artist] = .common(meta?.artist ?? record.artistName ?? "")
        fields[.album] = .common(meta?.album ?? record.albumTitle ?? "")
        fields[.albumArtist] = .common(meta?.albumArtist ?? "")
        fields[.genre] = .common(meta?.genre ?? record.genre ?? "")
        fields[.composer] = .common(meta?.composer ?? "")
        fields[.year] = .common(meta?.year.map(String.init) ?? "")
        fields[.trackNumber] = .common(numberText(meta?.trackNumber ?? record.trackNumber))
        fields[.discNumber] = .common(numberText(meta?.discNumber ?? record.discNumber))
        return TagFormModel(fields: fields)
    }

    /// Builds the form for a BATCH. Database-backed fields collapse to a shared
    /// value or a "(Multiple Values)" placeholder across the selection; the
    /// file-only fields (albumArtist / composer / year) start as placeholders
    /// (their per-file values are not known without reading every file) and are
    /// written only if the user explicitly sets them.
    static func batch(records: [TrackRecord]) -> TagFormModel {
        var fields: [TagField: TagFieldState] = [:]
        fields[.title] = collapse(records.map(\.title))
        fields[.artist] = collapse(records.map(\.artistName))
        fields[.album] = collapse(records.map(\.albumTitle))
        fields[.genre] = collapse(records.map(\.genre))
        fields[.trackNumber] = collapse(records.map { numberText($0.trackNumber) })
        fields[.discNumber] = collapse(records.map { numberText($0.discNumber) })
        fields[.albumArtist] = .mixed
        fields[.composer] = .mixed
        fields[.year] = .mixed
        return TagFormModel(fields: fields)
    }

    /// Collapses one field's values across the selection into a shared value or a
    /// mixed placeholder. `nil` and `""` are treated identically (both "absent").
    static func collapse(_ values: [String?]) -> TagFieldState {
        let normalized = Set(values.map { $0 ?? "" })
        if normalized.count <= 1 {
            return .common(normalized.first ?? "")
        }
        return .mixed
    }

    private static func numberText(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }
}

// MARK: - Patch diff

public extension TagFormModel {
    /// Builds a ``WritableMetadata`` carrying ONLY the user-edited fields. Every
    /// untouched field stays `nil` (= leave on disk unchanged). Numeric fields are
    /// written only when they parse to an `Int`; an unparseable/blank numeric edit
    /// is skipped (``WritableMetadata`` has no "clear a number" affordance).
    /// Artwork is included verbatim from ``artwork``.
    func makePatch() -> WritableMetadata {
        var patch = WritableMetadata()
        for field in TagField.allCases {
            guard let state = fields[field], state.isDirty else { continue }
            let value = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
            apply(field: field, value: value, to: &patch)
        }
        switch artwork {
        case .unchanged:
            break
        case .remove:
            patch.artwork = []
        case let .replace(data, mimeType):
            patch.artwork = [EmbeddedArtwork(data: data, mimeType: mimeType, type: .frontCover)]
        }
        return patch
    }

    private func apply(field: TagField, value: String, to patch: inout WritableMetadata) {
        switch field {
        case .title: patch.title = value
        case .artist: patch.artist = value
        case .album: patch.album = value
        case .albumArtist: patch.albumArtist = value
        case .genre: patch.genre = value
        case .composer: patch.composer = value
        case .year: patch.year = Int(value)
        case .trackNumber: patch.trackNumber = Int(value)
        case .discNumber: patch.discNumber = Int(value)
        }
    }
}

// MARK: - Online auto-fill (fill-missing-only)

public extension TagFormModel {
    /// Fills ONLY empty (or batch-"mixed") fields from an online
    /// ``MetadataLookupResult``, marking each filled field dirty so Save writes it.
    /// A field that already holds text is left exactly as the user has it —
    /// auto-fill NEVER overwrites an existing value or a manual edit. Composer and
    /// artwork are not provided by the lookup, so they are never touched here.
    mutating func fillMissing(from result: MetadataLookupResult) {
        fillIfEmpty(.title, result.title)
        fillIfEmpty(.artist, result.artist)
        fillIfEmpty(.album, result.album)
        fillIfEmpty(.albumArtist, result.albumArtist)
        fillIfEmpty(.genre, result.genre)
        fillIfEmpty(.year, result.year.map(String.init))
        fillIfEmpty(.trackNumber, result.trackNumber.map(String.init))
        fillIfEmpty(.discNumber, result.discNumber.map(String.init))
    }

    /// Sets `field` to `value` only when the field is currently empty (or a mixed
    /// batch placeholder) AND `value` is non-blank; otherwise leaves it untouched.
    private mutating func fillIfEmpty(_ field: TagField, _ value: String?) {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return
        }
        let state = fields[field]
        let current = state?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isEmpty = current.isEmpty || state?.isMixed == true
        guard isEmpty else { return }
        setField(field, to: trimmed)
    }
}

// MARK: - Self-check (pure, runnable in each shell's tag-editor `#Preview`)

/// A dependency-free verification of the mixed-value collapse and dirty-only
/// patch diff. It touches no disk and can be eyeballed in the Xcode canvas (each
/// row renders PASS/FAIL) — the same convention the shells use for app-target
/// logic that no `swift test` target can reach. The package `TagEditModelTests`
/// suite locks the same behaviour as first-class unit tests.
public enum TagFormSelfCheck {
    public struct Outcome: Equatable {
        public var name: String
        public var passed: Bool
    }

    public static func run() -> [Outcome] {
        [
            batchCommonValueShown(),
            batchMixedValuePlaceholder(),
            untouchedFieldsNotWritten(),
            onlyEditedFieldsWritten(),
            numericParsedAndBlankSkipped(),
            artworkRemoveClears(),
            artworkReplaceCarriesData(),
            autoFillFillsOnlyEmptyFields(),
        ]
    }

    private static func batchCommonValueShown() -> Outcome {
        let records = [track(album: "Reign In Blood"), track(album: "Reign In Blood")]
        let form = TagFormModel.batch(records: records)
        let album = form.fields[.album]
        return Outcome(
            name: "batch shows shared value",
            passed: album?.isMixed == false && album?.text == "Reign In Blood"
        )
    }

    private static func batchMixedValuePlaceholder() -> Outcome {
        let records = [track(album: "One"), track(album: "Two")]
        let form = TagFormModel.batch(records: records)
        let album = form.fields[.album]
        return Outcome(
            name: "batch flags mixed values",
            passed: album?.isMixed == true && album?.text.isEmpty == true
        )
    }

    private static func untouchedFieldsNotWritten() -> Outcome {
        let form = TagFormModel.single(record: track(name: "Angel of Death"), fileMetadata: nil)
        return Outcome(
            name: "untouched edit writes nothing",
            passed: form.makePatch().isEmpty
        )
    }

    private static func onlyEditedFieldsWritten() -> Outcome {
        var form = TagFormModel.single(record: track(name: "Old", album: "Album"), fileMetadata: nil)
        form.setField(.title, to: "New")
        let patch = form.makePatch()
        return Outcome(
            name: "only edited field is written",
            passed: patch.title == "New" && patch.artist == nil && patch.album == nil
        )
    }

    private static func numericParsedAndBlankSkipped() -> Outcome {
        var form = TagFormModel.single(record: track(), fileMetadata: nil)
        form.setField(.year, to: "1986")
        form.setField(.trackNumber, to: "")
        let patch = form.makePatch()
        return Outcome(
            name: "numeric parsed, blank skipped",
            passed: patch.year == 1986 && patch.trackNumber == nil
        )
    }

    private static func artworkRemoveClears() -> Outcome {
        var form = TagFormModel.single(record: track(), fileMetadata: nil)
        form.setArtwork(.remove)
        return Outcome(
            name: "artwork remove clears all",
            passed: form.makePatch().artwork == []
        )
    }

    private static func artworkReplaceCarriesData() -> Outcome {
        var form = TagFormModel.single(record: track(), fileMetadata: nil)
        let bytes = Data([0xFF, 0xD8, 0xFF])
        form.setArtwork(.replace(data: bytes, mimeType: "image/jpeg"))
        let patch = form.makePatch()
        return Outcome(
            name: "artwork replace carries bytes",
            passed: patch.artwork?.first?.data == bytes && patch.artwork?.first?.type == .frontCover
        )
    }

    private static func autoFillFillsOnlyEmptyFields() -> Outcome {
        var form = TagFormModel.single(record: track(name: "Keep Me", album: ""), fileMetadata: nil)
        var lookup = MetadataLookupResult()
        lookup.title = "Override"
        lookup.album = "Filled In"
        lookup.year = 1991
        form.fillMissing(from: lookup)
        let title = form.fields[.title]
        let album = form.fields[.album]
        let year = form.fields[.year]
        return Outcome(
            name: "auto-fill fills only empty fields",
            passed: title?.text == "Keep Me" && title?.isDirty != true
                && album?.text == "Filled In" && album?.isDirty == true
                && year?.text == "1991"
        )
    }

    private static func track(
        name: String? = nil,
        album: String? = nil
    ) -> TrackRecord {
        TrackRecord(filePath: "/music/\(UUID().uuidString).flac", title: name, albumTitle: album)
    }
}
