// LibraryScanner+Cue — `.cue` sidecar detection, expansion and whole-file suppression.
//
// A `.cue` sheet is TEXT, never audio. It is parsed through `CueSheetParser` and never
// reaches ``MetadataReading``, and it never becomes a `track` row of its own. What it
// produces is one row per ``CueTrack``, each carrying the AUDIO file's path as
// `filePath` — the hard invariant ``LibraryVisibility``'s LIKE-matching predicate
// depends on — and the segment's own `cueStartFrame`.
//
// # The two halves of "one file, many rows"
//   * FRESH scan: the audio file a sheet covers produces NO whole-file candidate, only
//     the N segment candidates. See ``LibraryScanner/expandCueSidecars(in:)``.
//   * UPGRADE: a whole-file row imported BEFORE the sheet appeared is RETAINED and
//     flagged `cueSuppressed = 1`. Deleting it would cascade playlistTrack /
//     profileTrackState / folderTrackOrder and orphan the bare-trackId stats rows.
import Foundation
import GRDB
import Metadata
import Persistence

extension ScanCandidate {
    /// The `(filePath, cueStartFrame)` row this candidate will become — the v20
    /// identity, which is what de-duplication and fingerprint-skip must key on.
    /// `filePath` alone would collapse a sheet's N segments into one.
    var trackIdentity: TrackRecord.Identity {
        TrackRecord.Identity(
            filePath: fingerprint.filePath,
            cueStartFrame: cue.map { Int64($0.track.startFrame) } ?? TrackRecord.wholeFileCueStartFrame
        )
    }
}

// MARK: - Sidecar expansion

/// What a pass over a URL list found in the way of `.cue` sheets.
struct CueExpansion {
    /// One candidate per resolved ``CueTrack``, in sheet order.
    var candidates: [ScanCandidate] = []
    /// The distinct AUDIO paths a sheet claims. A fresh scan drops these from the
    /// whole-file candidate list; any row already imported for one is suppressed.
    var coveredPaths: [String] = []
    /// Sheets that could not be parsed, plus every `FILE` that did not resolve —
    /// each is a row the user expected and did not get.
    var failed: Int = 0
}

extension LibraryScanner {
    /// Parses every `.cue` in `urls` and expands it into per-segment candidates.
    ///
    /// A sheet that throws and a `FILE` that does not resolve are both counted as
    /// failures rather than aborting: one dead reference in a multi-FILE sheet must
    /// never discard the tracks that did resolve.
    func expandCueSidecars(in urls: [URL]) -> CueExpansion {
        var expansion = CueExpansion()
        var covered: Set<String> = []
        for url in urls where url.pathExtension.lowercased() == CueSheetParser.pathExtension {
            guard let sheet = try? CueSheetParser.parse(sheetURL: url) else {
                expansion.failed += 1
                continue
            }
            expansion.failed += sheet.unresolvedFiles.count
            for track in sheet.tracks {
                if covered.insert(track.filePath).inserted {
                    expansion.coveredPaths.append(track.filePath)
                }
                guard let candidate = Self.makeCueCandidate(sheet: sheet, track: track) else {
                    expansion.failed += 1
                    continue
                }
                expansion.candidates.append(candidate)
            }
        }
        return expansion
    }

    /// Fingerprints the AUDIO file a segment lives in. The locator already proved the
    /// file exists; an unstattable path here means it vanished mid-scan.
    private static func makeCueCandidate(sheet: CueSheet, track: CueTrack) -> ScanCandidate? {
        let url = URL(fileURLWithPath: track.filePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: track.filePath) else {
            return nil
        }
        return ScanCandidate(
            url: url,
            mtime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            cue: CueSegment(sheet: sheet, track: track)
        )
    }
}

// MARK: - Retain-and-hide

extension LibraryScanner {
    /// Flags any pre-existing whole-file row for a cue-covered path as superseded.
    ///
    /// Runs once per scan, BEFORE the chunk loop, so the flag is set whether or not
    /// this scan has any segment work left to do (a re-scan skips every segment on
    /// its fingerprint yet must still converge). The `cueSuppressed = 0` predicate
    /// makes it idempotent, and `cueStartFrame = ?` pins it to the whole-file row so
    /// a segment can never suppress itself.
    ///
    /// Opens no transaction when nothing is covered, so a library with no `.cue`
    /// sheets pays exactly what it paid before.
    func suppressWholeFileRows(coveredPaths: [String]) {
        guard !coveredPaths.isEmpty else { return }
        try? database.writer.write { db in
            var index = 0
            while index < coveredPaths.count {
                let end = min(index + Self.inClauseLimit, coveredPaths.count)
                let slice = Array(coveredPaths[index ..< end])
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
                var arguments: [any DatabaseValueConvertible] = slice
                arguments.append(TrackRecord.wholeFileCueStartFrame)
                try db.execute(sql: """
                UPDATE track SET cueSuppressed = 1
                WHERE filePath IN (\(placeholders)) AND cueStartFrame = ? AND cueSuppressed = 0
                """, arguments: StatementArguments(arguments))
                index = end
            }
        }
    }
}

// MARK: - Segment → row

extension LibraryScanner {
    /// Maps one cue segment to a `TrackRecord` shaped for insert.
    ///
    /// Cue text wins over the audio file's own tags for the per-segment fields
    /// (a sheet describes the segments; the file's tags describe the whole rip),
    /// and the file's tags are the fallback. Stream properties, size and mtime are
    /// always the AUDIO file's — every segment shares them.
    static func makeCueRecord(
        metadata: TrackMetadata,
        candidate: ScanCandidate,
        segment: CueSegment
    ) -> TrackRecord {
        let sheet = segment.sheet
        let track = segment.track
        let title = track.title ?? metadata.title
        return TrackRecord(
            filePath: candidate.fingerprint.filePath,
            title: title,
            sortTitle: SortKey.sortKeyOrNil(title) ?? metadata.sortTitle,
            artistName: track.performer ?? sheet.performer ?? metadata.artist,
            albumTitle: sheet.title ?? metadata.album,
            trackNumber: track.number,
            discNumber: metadata.discNumber,
            duration: segmentDuration(track: track, fileDuration: metadata.duration),
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
            genre: GenreNormalizer.normalize(sheet.genre ?? metadata.genre),
            albumArtist: sheet.performer ?? metadata.albumArtist,
            composer: metadata.composer,
            year: leadingYear(in: sheet.date) ?? metadata.year,
            channelCount: metadata.channelCount,
            cueSheetPath: sheet.sheetPath,
            cueStartFrame: Int64(track.startFrame),
            cueEndFrame: track.endFrame.map(Int64.init)
        )
    }

    /// The segment's length, or — for a FILE's last segment, whose `endFrame` is
    /// `nil` — what remains of the audio file after its start. Never negative: a
    /// sheet whose offsets overrun the file would otherwise store a negative time.
    private static func segmentDuration(track: CueTrack, fileDuration: Double?) -> Double? {
        if let bounded = track.durationSeconds {
            return bounded
        }
        guard let fileDuration else { return nil }
        return max(0, fileDuration - CueTime.seconds(frames: track.startFrame))
    }

    /// `REM DATE` is verbatim text — sheets carry both `1997` and `1997-04-29` —
    /// so the year is its leading four digits, or nothing.
    private static func leadingYear(in date: String?) -> Int? {
        guard let date else { return nil }
        let digits = date.prefix(4)
        guard digits.count == 4, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else {
            return nil
        }
        return Int(digits)
    }
}
