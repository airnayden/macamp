// LibraryScanner — per-chunk processing: fingerprint classification, bounded
// concurrent metadata reads, and the batched single-transaction write.
//
// One chunk issues at most: 1 read transaction (fetch existing by path) and
// 1–2 write transactions (insert new via TrackRepository.insertBatch; update
// changed via writer.write). The transaction count is independent of the chunk
// size, which is what keeps a 100k import's lock pressure bounded.
import Foundation
import GRDB
import Metadata
import Persistence

extension LibraryScanner {
    /// Processes one chunk end-to-end. Returns the chunk's tally, or `nil` if the
    /// scan was cancelled after metadata was read but before persistence — so the
    /// caller stops and the chunk is left for a resumable re-scan.
    func processChunk(_ chunk: ArraySlice<ScanCandidate>) async -> ScanSummary? {
        let existing = (try? fetchExisting(paths: chunk.map(\.fingerprint.filePath))) ?? [:]

        var toRead: [ScanCandidate] = []
        var updateTargets: [TrackRecord.Identity: TrackRecord] = [:]
        var skipped = 0
        for candidate in chunk {
            classify(candidate, existing: existing, toRead: &toRead, updateTargets: &updateTargets, skipped: &skipped)
        }

        let readResults = await readMetadata(for: toRead)
        if Task.isCancelled {
            return nil // resumable: drop this chunk's uncommitted work
        }

        var inserts: [TrackRecord] = []
        var updates: [TrackRecord] = []
        var failed = 0
        for (candidate, metadata) in readResults {
            guard let metadata else {
                failed += 1
                continue
            }
            stage(
                metadata: metadata,
                candidate: candidate,
                updateTargets: updateTargets,
                inserts: &inserts,
                updates: &updates
            )
        }

        return persistChunk(inserts: inserts, updates: updates, skipped: skipped, failed: failed)
    }

    /// Sorts one candidate into skip / read-for-update / read-for-insert by
    /// comparing its fingerprint against any existing row.
    private func classify(
        _ candidate: ScanCandidate,
        existing: [TrackRecord.Identity: TrackRecord],
        toRead: inout [ScanCandidate],
        updateTargets: inout [TrackRecord.Identity: TrackRecord],
        skipped: inout Int
    ) {
        let identity = candidate.trackIdentity
        guard let row = existing[identity] else {
            toRead.append(candidate) // new row
            return
        }
        if fingerprintMatches(row, candidate.fingerprint) {
            skipped += 1 // unchanged — never re-read tags
        } else {
            updateTargets[identity] = row // changed — re-read and update in place
            toRead.append(candidate)
        }
    }

    /// Maps freshly-read metadata to an insert or an update record.
    private func stage(
        metadata: TrackMetadata,
        candidate: ScanCandidate,
        updateTargets: [TrackRecord.Identity: TrackRecord],
        inserts: inout [TrackRecord],
        updates: inout [TrackRecord]
    ) {
        var record = candidate.cue.map { segment in
            Self.makeCueRecord(metadata: metadata, candidate: candidate, segment: segment)
        } ?? makeRecord(metadata: metadata, candidate: candidate)
        if let previous = updateTargets[candidate.trackIdentity] {
            // Preserve identity + library bookkeeping across an update.
            record.id = previous.id
            record.dateAdded = previous.dateAdded
            updates.append(record)
        } else {
            inserts.append(record)
        }
    }

    /// `true` when the stored row's size + mtime match the candidate's, i.e. the
    /// file is byte-for-byte unchanged since the last scan.
    private func fingerprintMatches(_ record: TrackRecord, _ fingerprint: FileFingerprint) -> Bool {
        record.fileSize == fingerprint.fileSize && record.mtime == fingerprint.mtime
    }

    // MARK: Read transaction

    /// Fetches existing rows for the chunk's paths in a single read transaction,
    /// sub-chunking the `IN (...)` list under the SQLite variable limit.
    ///
    /// Keyed by the v20 `(filePath, cueStartFrame)` identity, NOT by path: a
    /// cue-covered file backs N rows, and a path-keyed map would keep whichever
    /// the query returned last — silently re-inserting the other N−1 segments on
    /// every scan. Paths are de-duplicated first because N segments of one file
    /// arrive as N copies of the same path and each would burn a bound variable.
    func fetchExisting(paths: [String]) throws -> [TrackRecord.Identity: TrackRecord] {
        let distinctPaths = Array(Set(paths))
        guard !distinctPaths.isEmpty else {
            return [:]
        }
        return try database.writer.read { db in
            var byIdentity: [TrackRecord.Identity: TrackRecord] = [:]
            var index = 0
            while index < distinctPaths.count {
                let end = min(index + LibraryScanner.inClauseLimit, distinctPaths.count)
                let slice = Array(distinctPaths[index ..< end])
                let rows = try TrackRecord
                    .filter(slice.contains(TrackRecord.Columns.filePath))
                    .fetchAll(db)
                for row in rows {
                    byIdentity[row.identity] = row
                }
                index = end
            }
            return byIdentity
        }
    }

    // MARK: Write transaction

    /// Persists one chunk in a single write transaction so it stays atomic: the
    /// artist/album graph is found-or-created and each record's `artistId`/`albumId`
    /// stamped before the row is written, never committing a dangling FK. A
    /// persistence error counts the chunk's writes as failures; an all-skipped
    /// chunk opens no transaction.
    private func persistChunk(
        inserts: [TrackRecord],
        updates: [TrackRecord],
        skipped: Int,
        failed: Int
    ) -> ScanSummary {
        guard !inserts.isEmpty || !updates.isEmpty else {
            return ScanSummary(added: 0, updated: 0, skipped: skipped, failed: failed)
        }
        do {
            try database.writer.write { db in
                var newRows = inserts
                var changedRows = updates
                try Self.resolveGraph(db, inserts: &newRows, updates: &changedRows)
                for index in newRows.indices {
                    try newRows[index].insert(db)
                }
                for record in changedRows {
                    try record.update(db)
                }
            }
            return ScanSummary(added: inserts.count, updated: updates.count, skipped: skipped, failed: failed)
        } catch {
            return ScanSummary(added: 0, updated: 0, skipped: skipped, failed: failed + inserts.count + updates.count)
        }
    }

    // MARK: Metadata read (bounded concurrency)

    /// Reads metadata for `candidates` with at most ``maxConcurrency`` reads in
    /// flight, preserving input order. A failed read yields `nil` (counted as a
    /// failure by the caller). Returns `[]` for an empty input.
    func readMetadata(for candidates: [ScanCandidate]) async -> [(ScanCandidate, TrackMetadata?)] {
        guard !candidates.isEmpty else {
            return []
        }
        // One read per distinct file: a `.cue` sheet points N segments at ONE audio
        // file, and re-reading it per segment would multiply a rip's tag I/O by N.
        var urls: [URL] = []
        var slotByPath: [String: Int] = [:]
        for candidate in candidates where slotByPath[candidate.url.path] == nil {
            slotByPath[candidate.url.path] = urls.count
            urls.append(candidate.url)
        }
        let readBySlot = await readMetadata(urls: urls)
        return candidates.map { candidate in
            (candidate, slotByPath[candidate.url.path].flatMap { readBySlot[$0] })
        }
    }

    /// Reads `urls` with at most ``maxConcurrency`` reads in flight, preserving
    /// input order. A failed read yields `nil` at that slot.
    private func readMetadata(urls: [URL]) async -> [TrackMetadata?] {
        guard !urls.isEmpty else {
            return []
        }
        let reader = metadataReader
        let cap = min(maxConcurrency, urls.count)

        let collected = await withTaskGroup(
            of: (Int, TrackMetadata?).self
        ) { group -> [(Int, TrackMetadata?)] in
            var results: [(Int, TrackMetadata?)] = []
            results.reserveCapacity(urls.count)
            var next = 0
            while next < cap {
                addRead(to: &group, urls: urls, index: next, reader: reader)
                next += 1
            }
            while let result = await group.next() {
                results.append(result)
                if next < urls.count {
                    addRead(to: &group, urls: urls, index: next, reader: reader)
                    next += 1
                }
            }
            return results
        }

        // Re-order by input index; an unfilled slot can only be a failed read.
        var byIndex = [TrackMetadata?](repeating: nil, count: urls.count)
        for (index, metadata) in collected {
            byIndex[index] = metadata
        }
        return byIndex
    }

    /// Schedules one metadata read; a thrown error becomes `nil`.
    private func addRead(
        to group: inout TaskGroup<(Int, TrackMetadata?)>,
        urls: [URL],
        index: Int,
        reader: any MetadataReading
    ) {
        let url = urls[index]
        group.addTask {
            (index, try? reader.readMetadata(from: url))
        }
    }

    // MARK: Mapping

    /// Maps read-only ``TrackMetadata`` + a fingerprint to a `TrackRecord` shaped
    /// for **insert** (id nil, playCount 0, `dateAdded` = now). Bitrate kbps→bps
    /// (×1000), sample rate Double→Int. Update callers overwrite id/dateAdded/
    /// playCount from the existing row.
    private func makeRecord(metadata: TrackMetadata, candidate: ScanCandidate) -> TrackRecord {
        TrackRecord(
            filePath: candidate.fingerprint.filePath,
            title: metadata.title,
            sortTitle: metadata.sortTitle,
            artistName: metadata.artist,
            albumTitle: metadata.album,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            duration: metadata.duration,
            bitrate: metadata.bitrate.map { Int(($0 * 1000).rounded()) },
            sampleRate: metadata.sampleRate.map { Int($0.rounded()) },
            bitDepth: metadata.bitDepth,
            fileSize: candidate.fingerprint.fileSize,
            mtime: candidate.fingerprint.mtime,
            dateAdded: Date().timeIntervalSince1970,
            replaygainTrackGain: metadata.replayGain?.trackGain,
            replaygainTrackPeak: metadata.replayGain?.trackPeak,
            replaygainAlbumGain: metadata.replayGain?.albumGain,
            replaygainAlbumPeak: metadata.replayGain?.albumPeak,
            genre: GenreNormalizer.normalize(metadata.genre),
            albumArtist: metadata.albumArtist,
            composer: metadata.composer,
            year: metadata.year,
            channelCount: metadata.channelCount
        )
    }
}

// MARK: - Artist/album graph (find-or-create + FK stamping)

extension LibraryScanner {
    /// Finds-or-creates every artist/album this chunk references and stamps each
    /// record's `artistId`/`albumId`. A per-chunk cache collapses the work to one
    /// fetch + at most one insert per distinct artist and album, so it stays cheap
    /// no matter how many tracks share an artist or album.
    fileprivate static func resolveGraph(
        _ db: Database,
        inserts: inout [TrackRecord],
        updates: inout [TrackRecord]
    ) throws {
        var caches = GraphCaches()
        try stampGraph(db, records: &inserts, caches: &caches)
        try stampGraph(db, records: &updates, caches: &caches)
    }

    /// Groups each track's album under its album-artist when tagged (compilation
    /// grouping), else its track artist. A blank artist or album leaves that FK
    /// `nil` — no "Unknown" placeholder rows are created.
    private static func stampGraph(
        _ db: Database,
        records: inout [TrackRecord],
        caches: inout GraphCaches
    ) throws {
        for index in records.indices {
            let artistName = nonEmpty(records[index].artistName)
            let albumTitle = nonEmpty(records[index].albumTitle)
            let albumArtist = nonEmpty(records[index].albumArtist)
            if let artistName {
                records[index].artistId = try findOrCreateArtist(db, name: artistName, caches: &caches)
            }
            guard let albumTitle else {
                continue
            }
            var ownerId: Int64?
            if let ownerName = albumArtist ?? artistName {
                ownerId = try findOrCreateArtist(db, name: ownerName, caches: &caches)
            }
            records[index].albumId = try findOrCreateAlbum(db, title: albumTitle, artistId: ownerId, caches: &caches)
        }
    }

    private static func findOrCreateArtist(
        _ db: Database,
        name: String,
        caches: inout GraphCaches
    ) throws -> Int64 {
        if let cached = caches.artists[name] {
            return cached
        }
        let existing = try ArtistRecord.filter(ArtistRecord.Columns.name == name).fetchOne(db)
        if let existing, let id = existing.id {
            caches.artists[name] = id
            return id
        }
        var record = ArtistRecord(name: name, sortName: name)
        try record.insert(db)
        let id = record.id ?? 0
        caches.artists[name] = id
        return id
    }

    private static func findOrCreateAlbum(
        _ db: Database,
        title: String,
        artistId: Int64?,
        caches: inout GraphCaches
    ) throws -> Int64 {
        let key = AlbumKey(title: title, artistId: artistId)
        if let cached = caches.albums[key] {
            return cached
        }
        let existing = try AlbumRecord
            .filter(AlbumRecord.Columns.title == title)
            .filter(AlbumRecord.Columns.artistId == artistId)
            .fetchOne(db)
        if let existing, let id = existing.id {
            caches.albums[key] = id
            return id
        }
        var record = AlbumRecord(title: title, sortTitle: title, artistId: artistId)
        try record.insert(db)
        let id = record.id ?? 0
        caches.albums[key] = id
        return id
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Composite identity of an album row — title plus owning-artist id (`nil` when
/// no artist resolved) — so the per-chunk album cache dedupes correctly.
private struct AlbumKey: Hashable {
    let title: String
    let artistId: Int64?
}

private struct GraphCaches {
    var artists: [String: Int64] = [:]
    var albums: [AlbumKey: Int64] = [:]
}
