// TagEditorViewModel — drives the macOS tag editor sheet.
//
// Owns the editor's loading and writing. It is `@MainActor @Observable` (the
// SwiftUI sheet binds straight to its `form`, `phase` and `results`) but EVERY
// filesystem / database operation runs OFF the main actor via `Task.detached`, so
// a tag write (which reads the whole file) never blocks the UI — the audio-thread
// and main-actor invariants are respected.
//
// macOS is NOT sandboxed, so — unlike the iOS twin — there is no security-scoped
// bookmark to resolve: writability is a plain filesystem question answered by
// ``MacWritableProbe`` (which mirrors ``SFBMetadataWriter``'s preflight). The file
// is read and written directly.
//
// Flow:
//   load()  → probe each track's writability (off-main); for a single track read
//             the file's current tags (incl. albumArtist/composer/year/artwork,
//             which the DB row doesn't store) and pre-fill the form; for a batch
//             pre-fill DB-backed fields with shared/"(Multiple Values)" placeholders.
//   save()  → build the dirty-only patch ONCE and apply it to each selected,
//             writable track: write atomically via ``SFBMetadataWriter`` (temp-copy
//             + rename, per-file rollback on failure), then resync that DB row from
//             the file via ``TrackRepository``. Each file gets an independent result.
//
// AppKit-free; reuses PlayerCore's ``SFBMetadataReader`` / ``SFBMetadataWriter``
// (never reimplements the writer).
//
// The pure form model (``TagFormModel`` / ``TagField``) is the SHARED PlayerCore
// `ViewModels` type; this view model deliberately stays per-shell (platform
// writability gating: macOS ``MacWritableProbe`` vs the iOS security-scoped path).
import CoreGraphics
import Foundation
import Metadata
import Persistence
import ViewModels

/// The per-track outcome of a batch write, surfaced to the UI.
struct TagWriteResult: Identifiable, Equatable {
    enum Outcome: Equatable {
        case success
        case unchanged
        case readOnly
        case failed(String)
    }

    var filePath: String
    var outcome: Outcome

    var id: String {
        filePath
    }

    var isFailure: Bool {
        switch outcome {
        case .failed, .readOnly: true
        case .success, .unchanged: false
        }
    }
}

/// The editor's lifecycle phase, driving the sheet's enabled/disabled UI.
enum TagEditorPhase: Equatable {
    case loading
    case ready
    case saving
    case finished
}

@MainActor
@Observable
final class TagEditorViewModel {
    /// The tracks being edited (1 = single, >1 = batch).
    let records: [TrackRecord]

    /// The editable form (bound directly by the view).
    var form = TagFormModel(fields: [:])
    /// The current lifecycle phase.
    var phase: TagEditorPhase = .loading
    /// `true` when NONE of the selected tracks can be written.
    var isReadOnly = false
    /// Per-track write outcomes, populated after ``save()``.
    var results: [TagWriteResult] = []
    /// A decoded preview of the artwork currently shown (replace target or the
    /// file's existing front cover), or `nil` for the no-art placeholder.
    var artworkPreview: CGImage?
    /// `true` while an online auto-fill lookup is in flight (drives the button spinner).
    var isAutoFilling = false

    @ObservationIgnored private let database: AppDatabase
    /// Resolves missing fields from an online database for the Auto-fill action.
    @ObservationIgnored private let metadataFetcher: any OnlineMetadataFetching
    /// Per-record writability (parallel to ``records``); `false` entries are
    /// read-only sources skipped on save.
    @ObservationIgnored private var writable: [Bool] = []

    init(records: [TrackRecord], database: AppDatabase, metadataFetcher: any OnlineMetadataFetching) {
        self.records = records
        self.database = database
        self.metadataFetcher = metadataFetcher
    }

    /// `true` when the batch spans more than one track.
    var isBatch: Bool {
        records.count > 1
    }

    /// Whether Save should be enabled: writable, has edits, not mid-flight.
    var canSave: Bool {
        !isReadOnly && form.hasChanges && phase == .ready
    }

    // MARK: - Load

    /// Probes writability, pre-fills the form, and (single) reads the file's
    /// current tags + artwork. Safe to call once.
    func load() async {
        let records = records
        let writableFlags = await Task.detached {
            records.map { MacWritableProbe.isWritable(filePath: $0.filePath) }
        }.value
        writable = writableFlags
        isReadOnly = !writableFlags.contains(true)

        if records.count == 1 {
            let path = records[0].filePath
            let metadata = await Task.detached { Self.readMetadata(atPath: path) }.value
            form = TagFormModel.single(record: records[0], fileMetadata: metadata)
            artworkPreview = metadata?.artwork.first.flatMap { AlbumArtImage.decode($0.data, maxPixel: 240) }
        } else {
            form = TagFormModel.batch(records: records)
        }
        phase = .ready
    }

    // MARK: - Edits (forwarded to the pure model)

    func setField(_ field: TagField, to text: String) {
        form.setField(field, to: text)
    }

    /// Replaces the artwork for the whole edit and refreshes the preview.
    func replaceArtwork(data: Data, mimeType: String?) {
        form.setArtwork(.replace(data: data, mimeType: mimeType))
        artworkPreview = AlbumArtImage.decode(data, maxPixel: 240)
    }

    /// Marks artwork for removal (writes `[]`) and clears the preview.
    func removeArtwork() {
        form.setArtwork(.remove)
        artworkPreview = nil
    }

    // MARK: - Save

    /// Writes the dirty-only patch to every selected, writable track atomically,
    /// resyncs each DB row, and records a per-file result. Returns when done.
    func save() async {
        guard canSave else { return }
        phase = .saving
        let patch = form.makePatch()
        let work = zip(records, writable).map { TrackWork(record: $0.0, isWritable: $0.1) }
        let database = database

        results = await Task.detached {
            let writer = SFBMetadataWriter(postsNotification: false)
            let reader = SFBMetadataReader()
            let repository = TrackRepository(database)
            return work.map { item in
                Self.write(patch, for: item, writer: writer, reader: reader, repository: repository)
            }
        }.value
        phase = .finished
    }

    // MARK: - Online auto-fill

    /// Looks up the current title + artist online and fills ONLY the empty fields
    /// with the best match, leaving the user to review and Save. Never overwrites a
    /// value the user already has. Single-track only (a batch has no single subject
    /// to look up). A lookup error is treated as "no match".
    ///
    /// A field the user has typed ALWAYS wins; a blank one falls back to
    /// ``FilenameMetadataGuess``, so an untagged file still asks a real question
    /// instead of sending the empty query the client short-circuits.
    ///
    /// - Returns: `true` when a match was found and applied; `false` otherwise.
    @discardableResult
    func autoFill() async -> Bool {
        guard !isAutoFilling, !isBatch else { return false }
        let guess = FilenameMetadataGuess.guess(fromFilePath: records.first?.filePath ?? "")
        let artistQuery = fieldText(.artist) ?? guess.artist
        let titleQuery = fieldText(.title) ?? guess.title
        guard artistQuery != nil || titleQuery != nil else { return false }
        isAutoFilling = true
        defer { isAutoFilling = false }
        let result = try? await metadataFetcher.lookup(
            artist: artistQuery,
            title: titleQuery,
            album: nil,
            duration: records.first?.duration
        )
        guard let result, !result.isEmpty else { return false }
        form.fillMissing(from: result)
        return true
    }

    /// The trimmed text of a field, or `nil` when blank.
    private func fieldText(_ field: TagField) -> String? {
        let text = form.fields[field]?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: - Off-main primitives (nonisolated, Sendable inputs only)

    /// A record + its writability, captured for the detached write.
    private struct TrackWork {
        var record: TrackRecord
        var isWritable: Bool
    }

    /// Reads a file's current tags. Returns `nil` when the file is unreadable.
    private nonisolated static func readMetadata(atPath path: String) -> TrackMetadata? {
        try? SFBMetadataReader().readMetadata(from: URL(fileURLWithPath: path))
    }

    /// Writes one file atomically and resyncs its DB row. The atomic writer leaves
    /// a failed file byte-for-byte unchanged — that IS the per-file rollback — so a
    /// failure here never corrupts the track or touches the other selected files.
    private nonisolated static func write(
        _ patch: WritableMetadata,
        for item: TrackWork,
        writer: SFBMetadataWriter,
        reader: SFBMetadataReader,
        repository: TrackRepository
    ) -> TagWriteResult {
        guard item.isWritable else {
            return TagWriteResult(filePath: item.record.filePath, outcome: .readOnly)
        }
        guard !patch.isEmpty else {
            return TagWriteResult(filePath: item.record.filePath, outcome: .unchanged)
        }
        let url = URL(fileURLWithPath: item.record.filePath)
        do {
            try writer.writeMetadata(patch, to: url)
            resync(record: item.record, from: url, reader: reader, repository: repository)
            return TagWriteResult(filePath: item.record.filePath, outcome: .success)
        } catch {
            return TagWriteResult(filePath: item.record.filePath, outcome: .failed("\(error)"))
        }
    }

    /// Re-reads the just-written file and updates the DB columns a tag edit can
    /// change — title, sortTitle, artist, album, track/disc number, genre (via
    /// `GenreNormalizer`), and the v6 columns albumArtist/composer/year. Identity +
    /// bookkeeping (id, dateAdded, playCount, availability, ReplayGain, stream
    /// props such as channelCount) are preserved.
    private nonisolated static func resync(
        record: TrackRecord,
        from url: URL,
        reader: SFBMetadataReader,
        repository: TrackRepository
    ) {
        guard let metadata = try? reader.readMetadata(from: url) else { return }
        var updated = record
        updated.title = metadata.title
        updated.sortTitle = metadata.sortTitle
        updated.artistName = metadata.artist
        updated.albumTitle = metadata.album
        updated.trackNumber = metadata.trackNumber
        updated.discNumber = metadata.discNumber
        updated.genre = GenreNormalizer.normalize(metadata.genre)
        updated.albumArtist = metadata.albumArtist
        updated.composer = metadata.composer
        updated.year = metadata.year
        try? repository.update(updated)
    }
}
