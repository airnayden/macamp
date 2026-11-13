// TagEditorViewModel — drives the iOS tag editor sheet.
//
// Owns the editor's loading, gating and writing. It is `@MainActor @Observable`
// (the SwiftUI view binds straight to its `form`, `phase` and `results`) but
// EVERY filesystem / database operation runs OFF the main actor via
// `Task.detached`, so a tag write (which reads the whole file) never blocks the
// UI — the audio-thread and main-actor invariants are respected.
//
// Flow:
//   load()  → resolve writable roots (off-main) → for a single writable track,
//             read the file's current tags (incl. albumArtist/composer/year/
//             artwork, which the DB row doesn't store) under security scope and
//             pre-fill the form; otherwise pre-fill from the DB row and mark the
//             editor read-only.
//   save()  → build the dirty-only patch ONCE and apply it to each selected
//             track: hold scope on the covering root, write atomically via
//             ``SFBMetadataWriter`` (temp-copy + rename, per-file rollback on
//             failure), then resync that DB row from the file via
//             ``TrackRepository``. Each file gets an independent result.
//
// AppKit/UIKit-free; reuses PlayerCore's ``SFBMetadataReader`` / ``SFBMetadataWriter``
// (never reimplements the writer) and the import target's balanced scoped-access
// helpers.
//
// The pure form model (``TagFormModel`` / ``TagField``) is the SHARED PlayerCore
// `ViewModels` type; this view model deliberately stays per-shell (platform
// writability gating: iOS ``WritableSource`` / security scope vs the macOS probe).
import CoreGraphics
import Foundation
import Metadata
import Persistence
import SwiftUI
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
    /// `true` when NONE of the selected tracks can be written (no bookmark).
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
    /// The covering writable root per record (parallel to ``records``); `nil`
    /// entries are read-only sources.
    @ObservationIgnored private var sources: [WritableSource?] = []

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

    /// Resolves writability, pre-fills the form, and (single + writable) reads the
    /// file's current tags + artwork under security scope. Safe to call once.
    func load() async {
        let database = database
        let records = records
        let resolved = await Task.detached {
            let roots = WritableSourceResolver.resolveRoots(database: database)
            return records.map { WritableSourceResolver.writableSource(forFilePath: $0.filePath, roots: roots) }
        }.value
        sources = resolved
        isReadOnly = resolved.allSatisfy { $0 == nil }

        if records.count == 1 {
            let metadata = resolved[0].flatMap { Self.readMetadata(at: $0) }
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
        let work = zip(records, sources).map { TrackWork(record: $0.0, source: $0.1) }
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

    /// A record + its writable source, captured for the detached write.
    private struct TrackWork {
        var record: TrackRecord
        var source: WritableSource?
    }

    /// Reads a file's current tags under balanced security scope. Returns `nil`
    /// when access was denied or the file is unreadable.
    private nonisolated static func readMetadata(at source: WritableSource) -> TrackMetadata? {
        withSecurityScopedAccess(to: source.rootURL) { didStart in
            guard didStart else { return nil }
            return try? SFBMetadataReader().readMetadata(from: source.trackURL)
        }
    }

    /// Writes one file atomically (held scope) and resyncs its DB row. The atomic
    /// writer leaves a failed file byte-for-byte unchanged — that IS the per-file
    /// rollback — so a failure here never corrupts the track.
    private nonisolated static func write(
        _ patch: WritableMetadata,
        for item: TrackWork,
        writer: SFBMetadataWriter,
        reader: SFBMetadataReader,
        repository: TrackRepository
    ) -> TagWriteResult {
        guard let source = item.source else {
            return TagWriteResult(filePath: item.record.filePath, outcome: .readOnly)
        }
        guard !patch.isEmpty else {
            return TagWriteResult(filePath: item.record.filePath, outcome: .unchanged)
        }
        let outcome: TagWriteResult.Outcome = withSecurityScopedAccess(to: source.rootURL) { didStart in
            guard didStart else { return .failed("access denied") }
            do {
                try writer.writeMetadata(patch, to: source.trackURL)
                resync(record: item.record, from: source.trackURL, reader: reader, repository: repository)
                return .success
            } catch {
                return .failed("\(error)")
            }
        }
        return TagWriteResult(filePath: item.record.filePath, outcome: outcome)
    }

    /// Re-reads the just-written file and updates the DB columns a tag edit can
    /// change (the file-only fields albumArtist/composer/year have no column), the
    /// same mapping the importer's `makeRecord` uses — genre via `GenreNormalizer`,
    /// sortTitle from the title. Identity + bookkeeping (id, dateAdded, playCount,
    /// availability, ReplayGain, stream props) are preserved.
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
        try? repository.update(updated)
    }
}
