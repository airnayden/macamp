// ProfileArchiveWritePlan — the whole import, as ONE transaction.
//
// Every method here runs inside a single `dbWriter.write`, so any throw anywhere
// rolls back the profile row along with everything hung off it. That is the
// all-or-nothing guarantee: a corrupt heatmap blob (rejected by
// `PlaySegmentHeatRecord.willSave`) or a malformed EQ preset can never leave a
// half-populated profile behind.
import Foundation
import GRDB

/// The immutable description of an import, and the code that performs it.
struct ProfileArchiveWritePlan {
    let archive: ProfileArchive
    let matcher: ProfileArchiveTrackMatcher
    let applyingSettingsAndEQPresets: Bool
    let importedPresetSuffix: String

    /// Performs the import and reports what it did — and what it had to drop.
    func write(into db: Database) throws -> ProfileArchiveImportSummary {
        let profileId = try insertProfile(into: db)
        try insertEvents(profileId: profileId, into: db)
        try insertRollups(profileId: profileId, into: db)
        let heat = try insertSegmentHeat(profileId: profileId, into: db)
        let states = try insertTrackStates(profileId: profileId, into: db)
        let presets = try insertEQPresets(into: db)
        return ProfileArchiveImportSummary(
            profileId: profileId,
            importedEvents: archive.events.count,
            importedRollups: archive.rollups.count,
            importedSegmentHeat: heat.imported,
            unmatchedSegmentHeat: heat.unmatched,
            importedTrackStates: states.imported,
            droppedTrackStates: states.dropped,
            importedEQPresets: presets.imported,
            renamedEQPresets: presets.renamed,
            settings: applyingSettingsAndEQPresets ? archive.settings : nil
        )
    }
}

// MARK: - Profile row

private extension ProfileArchiveWritePlan {
    /// Inserts the NEW profile. `id` is `nil` so SQLite assigns a fresh rowid —
    /// Guest keeps id 1 and no existing profile is ever touched.
    ///
    /// `avatarImagePath` is nulled (machine-local) and the PIN columns stay nil (the
    /// archive has no field to carry them), so neither can survive the trip.
    func insertProfile(into db: Database) throws -> Int64 {
        var record = ProfileRecord(
            id: nil,
            name: archive.profile.name,
            lastName: archive.profile.lastName,
            bio: archive.profile.bio,
            avatarId: archive.profile.avatarId,
            avatarImagePath: nil,
            pinHash: nil,
            pinSalt: nil,
            createdAt: Date(timeIntervalSince1970: archive.profile.createdAt)
        )
        try record.insert(db)
        return record.id ?? 0
    }
}

// MARK: - Statistics (restored unconditionally)

private extension ProfileArchiveWritePlan {
    /// Events restore in full. `trackId` is a best-effort backlink with no foreign
    /// key, so an unmatched track simply leaves it `NULL` — every facet the digest
    /// computes comes from the snapshot columns beside it.
    func insertEvents(profileId: Int64, into db: Database) throws {
        for event in archive.events {
            var record = PlayEventRecord(
                profileId: profileId,
                trackId: matcher.localTrackId(for: event.track),
                artistName: event.track.artistName,
                title: event.track.title,
                albumTitle: event.track.albumTitle,
                genre: event.genre,
                durationSeconds: event.track.durationSeconds,
                startedAt: event.startedAt,
                utcOffsetSeconds: event.utcOffsetSeconds,
                secondsListened: event.secondsListened,
                completionFraction: event.completionFraction,
                skipped: event.skipped,
                sourceSurface: event.sourceSurface,
                shuffle: event.shuffle
            )
            try record.insert(db)
        }
    }

    func insertRollups(profileId: Int64, into db: Database) throws {
        for rollup in archive.rollups {
            var record = PlayEventRollupRecord(
                profileId: profileId,
                yearMonth: rollup.yearMonth,
                artistKey: rollup.artistKey,
                genreKey: rollup.genreKey,
                plays: rollup.plays,
                listenedSeconds: rollup.listenedSeconds,
                skips: rollup.skips,
                completions: rollup.completions
            )
            try record.insert(db)
        }
    }

    /// Heatmaps restore in full. An unmatched track — or a second archived row that
    /// would land on an id this import already used — gets a SYNTHETIC NEGATIVE id.
    ///
    /// That is safe by construction: the column has no foreign key, SQLite rowids are
    /// always positive so no real track can collide, the scrubber overlay only ever
    /// looks up the positive id of the track it is playing, and the digest reads the
    /// row's own identity snapshot. So unmatched heat still feeds `mostReplayed`
    /// while being unable to attach to the WRONG song.
    func insertSegmentHeat(profileId: Int64, into db: Database) throws -> (imported: Int, unmatched: Int) {
        var usedTrackIds: Set<Int64> = []
        var syntheticTrackId: Int64 = -1
        var unmatched = 0
        for heat in archive.segmentHeat {
            let matched = matcher.localTrackId(for: heat.track)
            let assigned: Int64
            if let matched, !usedTrackIds.contains(matched) {
                assigned = matched
            } else {
                assigned = syntheticTrackId
                syntheticTrackId -= 1
                unmatched += 1
            }
            usedTrackIds.insert(assigned)
            var record = PlaySegmentHeatRecord(
                profileId: profileId,
                trackId: assigned,
                artistName: heat.track.artistName,
                title: heat.track.title,
                albumTitle: heat.track.albumTitle,
                genre: heat.genre,
                durationSeconds: heat.track.durationSeconds ?? 0,
                bucketCounts: heat.bucketCounts,
                totalPasses: heat.totalPasses,
                updatedAt: heat.updatedAt
            )
            try record.insert(db)
        }
        return (archive.segmentHeat.count, unmatched)
    }

    /// Counter rows import ONLY for matched tracks: `profileTrackState.trackId` is a
    /// real foreign key, so there is nowhere to put a row whose track is not here.
    /// The drop count is reported rather than swallowed.
    func insertTrackStates(profileId: Int64, into db: Database) throws -> (imported: Int, dropped: Int) {
        var seenTrackIds: Set<Int64> = []
        var imported = 0
        for state in archive.trackStates {
            guard let localId = matcher.localTrackId(for: state.track),
                  seenTrackIds.insert(localId).inserted
            else {
                continue
            }
            try ProfileTrackStateRecord(
                profileId: profileId,
                trackId: localId,
                isFavourite: state.isFavourite,
                playCount: state.playCount,
                listenedCount: state.listenedCount,
                customPosition: state.customPosition
            ).insert(db)
            imported += 1
        }
        return (imported, archive.trackStates.count - imported)
    }
}

// MARK: - Equalizer (opt-in, never overwriting)

private extension ProfileArchiveWritePlan {
    /// Inserts the archived custom presets, renaming any whose name is taken.
    ///
    /// `eqPreset.name` is `UNIQUE`, and overwriting someone's tuning silently would
    /// be the worst possible reading of "import a profile" — so a collision always
    /// becomes a NEW preset under a suffixed name and the original is left alone.
    func insertEQPresets(into db: Database) throws -> (imported: Int, renamed: [String]) {
        guard applyingSettingsAndEQPresets else { return (0, []) }
        var renamed: [String] = []
        var imported = 0
        for preset in archive.eqPresets {
            guard preset.bandGains.count == ProfileArchiveEQPreset.bandCount else {
                throw ProfileArchiveError.invalidEQPreset(
                    name: preset.name,
                    bandCount: preset.bandGains.count
                )
            }
            let name = try availableName(for: preset.name, in: db)
            if name != preset.name { renamed.append(name) }
            var record = try EQPresetRecord(preset: EQPreset(
                name: name,
                bandGains: preset.bandGains.map(Float.init),
                preamp: preset.preamp.map(Float.init)
            ))
            try record.insert(db)
            imported += 1
        }
        return (imported, renamed)
    }

    /// The first free name from `name`, `"name <suffix>"`, `"name <suffix> 2"`, …
    ///
    /// The candidate list is one longer than the number of presets that exist, so by
    /// the pigeonhole principle at least one of them is always free — the function is
    /// total without an unbounded loop.
    func availableName(for name: String, in db: Database) throws -> String {
        let suffixed = "\(name) \(importedPresetSuffix)"
        let existing = try EQPresetRecord.fetchCount(db)
        var candidates = [name, suffixed]
        candidates.append(contentsOf: (2 ... (existing + 2)).map { "\(suffixed) \($0)" })
        for candidate in candidates {
            let taken = try EQPresetRecord
                .filter(EQPresetRecord.Columns.name == candidate)
                .fetchCount(db) > 0
            if !taken { return candidate }
        }
        return suffixed
    }
}
