//
//  LoudnessScanService+Album.swift
//  MacAMP PlayerCore — Services
//
//  Album gain: pool the gating blocks of every track on an album and re-derive
//  ONE relative gate across the whole set (the beets method — see
//  ``AlbumLoudnessPooling``).
//
//  THE THREE RULES THIS FILE EXISTS TO ENFORCE:
//
//  1. POOLING SOURCE. A member outside the current page contributes its STORED
//     `blockPowersHistogram`, read back through the repository. A page-50 batch
//     routinely splits an album, and a member is NEVER re-decoded merely to pool
//     it — that would make album gain cost O(album size) per page instead of one
//     bounded read.
//
//  2. COMPLETENESS. A group is pooled only when EVERY member has a non-null
//     histogram at the current ``LoudnessScanService/analysisVersion``. On
//     completion the result is written back to ALL members, including ones that
//     were already scanned on a previous run — so a group can never hold two
//     different album figures, and a partial group never leaves a stale one.
//
//  3. FAIL-CLOSED DENOMINATOR. A member that FAILED to scan wrote no row, and it
//     is NOT filtered out of the membership: the group simply stays incomplete
//     and both album fields remain NULL. Excluding failures would see "1 of 1"
//     on a two-track album and publish an album gain derived from half of it.
//
//  All three apply IDENTICALLY to both grouping rules below.
//
//  TWO GROUPING RULES, ONE PARTITION. A whole-file row groups by `track.albumId`
//  (`nil` ⇒ no album, both fields stay NULL); a CUE segment groups by
//  `COALESCE(track.cueSheetPath, track.filePath)`. The two are selected by
//  complementary tests on `track.cueStartFrame` (`= -1` versus `!= -1`), and that
//  is what keeps them a partition rather than two overlapping views: cue rows DO
//  carry an `albumId` — the scanner assigns one whenever the sheet names an album
//  — so without the `= -1` qualifier on the album query every segment would be
//  pooled TWICE and the surviving `albumLUFS` would depend on which write landed
//  last. The group key is a total function of the row, so no row can reach two
//  groups. Both `cueStartFrame` references are table-qualified because
//  `trackLoudness` carries a column of the same name.
//
//  WHY THE SHEET PATH AND NOT THE FILE PATH. A multi-FILE cue sheet gives each
//  segment a DIFFERENT `filePath` with `cueStartFrame` typically 0, so file-path
//  grouping would shatter one album into singleton groups whose pooled figure
//  degenerates to the track figure. The sheet path covers both layouts and gives
//  the identical partition for a single-file disc image; the `COALESCE` fallback
//  only catches a segment written without one.
//
//  PlayerCore portability: Foundation + GRDB through Persistence.
//

import Foundation
import GRDB
import Persistence

// MARK: - Album pooling

extension LoudnessScanService {
    /// Attempts to pool every group the finished page touched, under both rules.
    ///
    /// Attempting on every page is what makes a split album work without any
    /// cross-page bookkeeping: the pages that complete only PART of a group find
    /// it incomplete and do nothing, and the page that lands its last member
    /// finds it complete and writes the figure to all of them at once.
    func poolAlbums(touchedBy candidates: [Candidate]) async {
        await poolAlbumIdGroups(touchedBy: candidates)
        await poolCueSheetGroups(touchedBy: candidates)
    }

    // MARK: Private — whole-file rows, grouped by albumId

    private func poolAlbumIdGroups(touchedBy candidates: [Candidate]) async {
        let albumIds = Set(
            candidates.filter { !$0.track.isCueSegment }.compactMap(\.albumId)
        ).sorted()
        for albumId in albumIds {
            if Task.isCancelled { return }
            let members = await albumMemberIds(albumId)
            await pool(memberIds: members)
        }
    }

    /// Every present WHOLE-FILE track on `albumId`, in `id` order.
    ///
    /// The membership — the completeness DENOMINATOR — is the album's present
    /// tracks. Availability is transient external state (an unmounted drive, a
    /// file being moved), and a `missing` member is not a member that failed to
    /// scan: freezing an album's gain until a disconnected volume returns would
    /// punish the ordinary case, whereas a PRESENT member that failed correctly
    /// keeps the group open because it is a candidate that produced no row.
    private func albumMemberIds(_ albumId: Int64) async -> [Int64]? {
        let sql = Self.albumMemberSQL
        return await memberIds(sql: sql, key: albumId.databaseValue)
    }

    // MARK: Private — cue segments, grouped by cue sheet

    private func poolCueSheetGroups(touchedBy candidates: [Candidate]) async {
        let sheetKeys = Set(candidates.compactMap(Self.cueGroupKey)).sorted()
        for key in sheetKeys {
            if Task.isCancelled { return }
            let members = await cueSheetMemberIds(key)
            await pool(memberIds: members)
        }
    }

    /// The pooling key for a cue segment, or `nil` for a whole-file row.
    private static func cueGroupKey(_ candidate: Candidate) -> String? {
        guard candidate.track.isCueSegment else { return nil }
        return candidate.track.cueSheetPath ?? candidate.track.filePath
    }

    /// Every present CUE segment sharing `key`, in `id` order — which for a disc
    /// image is the sheet's own playing order.
    private func cueSheetMemberIds(_ key: String) async -> [Int64]? {
        let sql = Self.cueSheetMemberSQL
        return await memberIds(sql: sql, key: key.databaseValue)
    }

    // MARK: Private — shared machinery

    /// - Returns: `nil` when the read failed, or when the group exceeds
    ///   ``AlbumLoudnessPooling/maximumMembers`` — a group that large is a data
    ///   error, not a box set, and is left unpooled rather than half-pooled by a
    ///   silently truncating batch read.
    private func memberIds(sql: String, key: DatabaseValue) async -> [Int64]? {
        let ceiling = AlbumLoudnessPooling.maximumMembers
        let ids = try? await database.writer.read { db -> [Int64] in
            try Int64.fetchAll(
                db,
                sql: sql,
                arguments: [key, Availability.present.rawValue, ceiling + 1]
            )
        }
        guard let ids, ids.count <= ceiling else { return nil }
        return ids
    }

    private func pool(memberIds: [Int64]?) async {
        guard let memberIds, !memberIds.isEmpty else { return }
        guard let records = await completeLoudness(forMembers: memberIds) else { return }
        guard let pooled = Self.pooledLoudness(of: records) else { return }
        try? await repository.applyAlbumLoudness(
            trackIds: memberIds,
            albumLUFS: pooled.lufs,
            albumPeak: pooled.peak
        )
    }

    /// The loudness rows of `memberIds`, or `nil` when the group is incomplete.
    ///
    /// One batch read suffices because ``AlbumLoudnessPooling/maximumMembers``
    /// IS ``TrackLoudnessRepository/fetchLimit``, and ``memberIds(sql:key:)``
    /// already refused anything larger. Ids with no row simply do not come back —
    /// which is exactly what "this group is not complete yet" looks like.
    private func completeLoudness(forMembers memberIds: [Int64]) async -> [TrackLoudnessRecord]? {
        guard let records = try? await repository.loudness(forTrackIds: memberIds) else { return nil }
        guard records.count == memberIds.count else { return nil }
        let version = Self.analysisVersion
        let usable = records.allSatisfy {
            $0.analysisVersion == version && $0.blockPowersHistogram != nil
        }
        return usable ? records : nil
    }

    /// The pooled album loudness and peak, or `nil` when the group carries no
    /// gate-passing audio at all (an album of pure silence).
    ///
    /// `albumPeak` is the MAXIMUM member true peak, per RG 2.0: album mode's
    /// anti-clip limit must hold for every track the album gain is applied to,
    /// so the loudest sample anywhere on the disc is the one that bounds it.
    private static func pooledLoudness(
        of records: [TrackLoudnessRecord]
    ) -> (lufs: Double, peak: Double)? {
        let blobs = records.compactMap(\.blockPowersHistogram)
        guard blobs.count == records.count else { return nil }
        guard let counts = try? BlockLoudnessHistogram.pooled(blobs: blobs) else { return nil }
        guard let lufs = AlbumLoudnessPooling.integratedLoudness(ofPooledHistogram: counts) else { return nil }
        return (lufs, records.map(\.truePeak).max() ?? 0)
    }

    /// Argument order is the `?` order in the string: album, availability, limit.
    private static var albumMemberSQL: String {
        """
        SELECT track.id FROM track
        WHERE track.albumId = ? AND track.availability = ?
          AND track.cueStartFrame = \(TrackRecord.wholeFileCueStartFrame)
        ORDER BY track.id ASC
        LIMIT ?
        """
    }

    /// Argument order is the `?` order in the string: sheet key, availability, limit.
    ///
    /// `COALESCE` is not indexable, so this is a table scan — acceptable because it
    /// runs only for a page that actually carried a cue segment, and a cue-free
    /// library therefore pays exactly what it paid before this rule existed.
    private static var cueSheetMemberSQL: String {
        """
        SELECT track.id FROM track
        WHERE COALESCE(track.cueSheetPath, track.filePath) = ? AND track.availability = ?
          AND track.cueStartFrame != \(TrackRecord.wholeFileCueStartFrame)
        ORDER BY track.id ASC
        LIMIT ?
        """
    }
}
