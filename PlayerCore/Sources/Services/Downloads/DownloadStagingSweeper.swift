// DownloadStagingSweeper — the launch-time sweep of abandoned yt-dlp leftovers, and
// the per-item purge that runs the moment one download is interrupted.
//
// yt-dlp is handed `-P temp:<staging>` so a partial transfer NEVER appears in the
// listener's music folder. The cost of that is a private directory that accumulates
// leftovers whenever the app dies before the engine finishes — a crash, a force-quit,
// a panic — or whenever a person cancels or pauses mid-flight. Nothing else ever
// cleans them up, so the shell sweeps the directory once at launch and the queue
// purges an interrupted row's own files immediately.
//
// ── THIS IS NOT HOUSEKEEPING: A PARTIAL CONTAINER IS *ADOPTED* ───────────────
//
// The matched set used to be `.part` / `.ytdl` / `.temp.*`, and this header used to
// say "deliberately the plan's three patterns and no more". That was wrong, and the
// way it was wrong is the worst failure a downloader has — silent, affirmative data
// loss reported to the listener as success.
//
// Interrupting a download DURING POST-PROCESSING kills the child while ffmpeg is
// muxing, which leaves a partial OUTPUT CONTAINER behind: `Title [id].m4a`, a
// structurally valid file that is merely short. It carries no partial marker, so none
// of the three patterns matched it and it survived every relaunch, forever. On the
// next attempt at that same video yt-dlp ADOPTS it as already-post-processed: it
// embeds art and tags onto it, moves it to the destination, prints
// `after_move:MACAMP-FILE|…` and EXITS 0. MacAMP maps exit-0-with-a-file-line to
// `.completed`, shows a success toast, and imports it. Measured: a 10 h 04 m source
// arrived as a 6 h 26 m file the app called finished. Nothing downstream can catch
// that — the file is valid, `ffprobe` is clean, and there is no stderr to read.
//
// So the rule is now shaped by the DIRECTORY rather than by a partial-marker suffix.
// The staging directory is app-private and NOT user-relocatable
// (`DownloadPrivateDirectories`), and the engine MOVES a finished file out of it, so
// any media container still sitting here is by definition abandoned. Note what this
// does NOT change: adopting a COMPLETE file is correct behaviour and still works —
// that file lives in the destination folder, which nothing in this file ever reads.
//
// ── WHY THE AGE GUARD IS NOT OPTIONAL ────────────────────────────────────────
//
// ``sweep(directory:now:staleAge:fileManager:)`` is a FILE sweep, not a process
// sweep, and the distinction is the whole reason ``staleAge`` exists. A child process
// outlives the app that spawned it: when MacAMP dies, its yt-dlp children are
// reparented to launchd and keep running — keep *writing* — until they finish or die
// on their own. A relaunch that deleted every leftover it found would therefore
// delete the file a live orphan is streaming into, corrupting a download that was
// going to succeed.
//
// An orphan writes continuously, so its file's mtime is always recent. One hour is far
// longer than any plausible write gap and far shorter than "forever", which makes
// `now - mtime > 1 hour` a sound proxy for "nothing is writing this". A file younger
// than that is LEFT ALONE, even though it is almost certainly garbage — the sweep runs
// on every launch, so it is picked up next time.
//
// This claims nothing about the orphan PROCESS: it is not signalled, not waited on,
// not counted. It finishes or dies by itself. Stated plainly here so no later reader
// mistakes the sweep for a supervision mechanism.
//
// ── WHY THE PURGE HAS *NO* AGE GUARD ─────────────────────────────────────────
//
// ``purgeArtifacts(ofVideoID:in:scope:fileManager:)`` deletes immediately, and that is
// deliberate: it only ever touches files carrying one row's own `[<videoID>]` marker,
// on a child MacAMP itself just signalled, and the retry that would adopt a partial
// container is one click away. Waiting an hour there would reintroduce the exact
// window this exists to close.
//
// Pure Foundation, no `Process`, no `URLSession` — the whole point is that both halves
// are testable under `swift test` with a seeded directory and an injected clock.
import Foundation

/// The canonical on-disk location of the download staging directory.
///
/// Resolve the directory through this type rather than re-deriving
/// `Application Support/MacAMP/Downloads-Staging/` at each call site, so the yt-dlp
/// `-P temp:` argument, the scanner's exclusion, and this sweep can never disagree.
/// Mirrors ``InstrumentalCacheLocation`` in `Models`, which owns the same problem for
/// the karaoke cache.
public enum DownloadStagingLocation {
    /// The staging directory's path relative to the Application Support container.
    public static let applicationSupportSubpath = "MacAMP/Downloads-Staging"

    /// The staging directory inside a given Application Support directory.
    ///
    /// Injectable form: pass a test-scoped Application Support URL to relocate the
    /// staging directory without touching the real container.
    public static func directory(inApplicationSupport applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("MacAMP", isDirectory: true)
            .appendingPathComponent("Downloads-Staging", isDirectory: true)
    }

    /// The default staging directory
    /// (`~/Library/Application Support/MacAMP/Downloads-Staging/`), or `nil` when the
    /// Application Support container cannot be located.
    ///
    /// Does not create the directory (`create: false`) — resolution only. The queue
    /// creates it lazily before the first spawn.
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        guard let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return directory(inApplicationSupport: base)
    }
}

/// How much of one interrupted row's staging footprint to reclaim.
///
/// The two cases exist because "the row is gone" and "the row is coming back" want
/// different answers, and collapsing them would cost real user value either way.
public enum DownloadStagingPurgeScope: Sendable, Equatable, Hashable, CaseIterable {
    /// Only the files a retry could ADOPT as already-finished output — the media
    /// containers — plus the conversion progress file, which belongs to one attempt and
    /// nothing else. Resumable state (`*.part`, `*.ytdl`) is deliberately KEPT.
    ///
    /// This is the FAILURE scope, and it is the only thing that still produces it: pause
    /// no longer cancels or requeues anything, so it reclaims nothing at all. A failure
    /// is the state a person retries most, and yt-dlp resumes into its own `.part` by
    /// default; deleting that would throw away a nearly-complete multi-hundred-megabyte
    /// transfer to solve a problem a `.part` does not have — a partial marked `.part` is
    /// never mistaken for finished output.
    case adoptableOutputs

    /// Every staging file carrying this row's marker, resumable state included.
    ///
    /// This is the cancel/quit scope. The row has been DROPPED, so its partials are
    /// not an asset any more — they are the unbounded staging growth a listener sees
    /// as hundreds of megabytes surviving a relaunch.
    case allArtifacts
}

/// Deletes yt-dlp leftovers: everything stale at launch, and one row's own files the
/// moment that row is interrupted.
public enum DownloadStagingSweeper {
    /// How old a leftover must be before ``sweep(directory:now:staleAge:fileManager:)``
    /// will delete it.
    ///
    /// See the file header: this is the guard that keeps a crash-orphaned,
    /// still-running yt-dlp from having its output deleted out from under it.
    public static let staleAge: TimeInterval = 3600

    /// The `*.temp.*` shape's marker. Matched as an INFIX (not a path extension)
    /// because the pattern is `<stem>.temp.<extension>` — `Song [id].temp.m4a`.
    private static let tempInfix = ".temp."

    /// The fragmented-download shape's marker — `<name>.part-Frag<N>`, written when a
    /// stream arrives in fragments. Also an infix: the index follows it.
    private static let fragmentInfix = ".part-Frag"

    /// Every file extension the engine can leave sitting inside the staging directory.
    ///
    /// Three groups, all of them produced by the argument vector MacAMP actually
    /// passes (`YtDlpCommandBuilder`): the audio containers `-x --audio-format` writes,
    /// the source containers a stream arrives in before extraction, and the
    /// thumbnail/sidecar files `--embed-thumbnail` / `--embed-metadata` leave behind.
    ///
    /// Safe to delete ONLY because of where it is applied. The staging directory is
    /// app-private and not user-relocatable, and the engine moves finished files out
    /// of it — so a media container still here is abandoned by definition. Pointing
    /// this predicate at the destination folder would destroy the listener's music,
    /// which is why nothing in this file ever reads that path.
    public static let abandonedOutputExtensions: Set<String> = [
        // Audio containers an extraction/transcode pass can write.
        "m4a", "m4b", "mp3", "opus", "ogg", "oga", "flac", "wav", "aac", "mka",
        // Source containers a stream arrives in before extraction.
        "webm", "mp4", "mkv", "mov", "avi", "flv", "3gp",
        // Thumbnail and sidecar files the embed passes fetch or emit.
        "webp", "jpg", "jpeg", "png", "json", "description", "meta",
    ]

    /// Whether `fileName` carries one of yt-dlp's PARTIAL MARKERS: `*.part`, `*.ytdl`,
    /// `*.temp.*`, or `*.part-Frag<N>`.
    ///
    /// Each pattern requires a non-empty stem, so a file named exactly `.part` (a
    /// dotfile that happens to share the name) is NOT a leftover.
    ///
    /// `.part-Frag<N>` was previously pinned as UNMATCHED with a note that widening a
    /// delete rule is a plan decision. It is matched now: closing the partial-container
    /// hole (file header) meant revisiting the whole set, and an abandoned fragment is
    /// the same unbounded-growth problem in a smaller file.
    public static func isIntermediate(_ fileName: String) -> Bool {
        if hasStem(fileName, before: ".part") { return true }
        if hasStem(fileName, before: ".ytdl") { return true }
        if hasSurroundedInfix(fragmentInfix, in: fileName) { return true }
        return hasSurroundedInfix(tempInfix, in: fileName)
    }

    /// Whether `fileName` is a media container or sidecar left behind in staging —
    /// the shape that carries NO partial marker and is therefore adoptable on a retry.
    ///
    /// Requires a non-empty stem for the same reason ``isIntermediate(_:)`` does: a
    /// bare `.m4a` dotfile is not engine output.
    public static func isAbandonedOutput(_ fileName: String) -> Bool {
        guard let dot = fileName.lastIndex(of: "."), dot > fileName.startIndex else { return false }
        let pathExtension = fileName[fileName.index(after: dot)...]
        return abandonedOutputExtensions.contains(pathExtension.lowercased())
    }

    /// Whether `fileName` is the ffmpeg conversion progress file MacAMP asks for via
    /// `--postprocessor-args` — `ffprogress [<id>].txt`.
    ///
    /// Its own predicate rather than another `.txt` row in
    /// ``abandonedOutputExtensions``: that set is applied to a directory the listener
    /// never chose, but `.txt` is the one extension a person plausibly drops there by
    /// hand, and MacAMP has no business deleting someone's notes. Matching the engine's
    /// own generated name — both ends, with something between them — keeps the rule as
    /// narrow as the thing it is reclaiming. The affixes come from
    /// ``YtDlpCommandBuilder`` so the name this matches is literally the name that is
    /// emitted.
    public static func isFFProgress(_ fileName: String) -> Bool {
        let prefix = YtDlpCommandBuilder.ffProgressNamePrefix
        let suffix = YtDlpCommandBuilder.ffProgressNameSuffix
        return fileName.hasPrefix(prefix)
            && fileName.hasSuffix(suffix)
            && fileName.count > prefix.count + suffix.count
    }

    /// Whether the launch sweep may delete `fileName`: a partial marker, an abandoned
    /// container, OR a conversion progress file. Anything else is left alone.
    public static func isSweepable(_ fileName: String) -> Bool {
        isIntermediate(fileName) || isAbandonedOutput(fileName) || isFFProgress(fileName)
    }

    /// The substring every file yt-dlp writes for one video carries.
    ///
    /// The output template is `%(title)s [%(id)s].%(ext)s`
    /// (``YtDlpCommandBuilder/outputTemplate``), so the bracketed canonical id appears
    /// in the source download, every intermediate, the post-processed container, and
    /// the thumbnail alike. Matching on it is what keeps one row's purge from touching
    /// another row's files.
    public static func artifactMarker(forVideoID videoID: String) -> String {
        "[" + videoID + "]"
    }

    /// Whether `fileName` is a staging artifact of `videoID` that `scope` covers.
    ///
    /// An empty `videoID` matches NOTHING — a marker of `[]` would otherwise sweep
    /// half the directory.
    public static func isArtifact(
        _ fileName: String,
        ofVideoID videoID: String,
        scope: DownloadStagingPurgeScope
    ) -> Bool {
        guard !videoID.isEmpty, fileName.contains(artifactMarker(forVideoID: videoID)) else { return false }
        switch scope {
        case .adoptableOutputs: return isAbandonedOutput(fileName) || isFFProgress(fileName)
        case .allArtifacts: return true
        }
    }

    /// Deletes every stale leftover directly inside `directory`.
    ///
    /// - Parameters:
    ///   - directory: The staging directory, and ONLY ever that. A missing or
    ///     unreadable one sweeps nothing.
    ///   - now: The clock, injectable so a test can age a seeded file deterministically.
    ///   - staleAge: The age threshold; see ``staleAge``.
    /// - Returns: The URLs actually deleted, for evidence and logging.
    @discardableResult
    public static func sweep(
        directory: URL,
        now: Date = Date(),
        staleAge: TimeInterval = DownloadStagingSweeper.staleAge,
        fileManager: FileManager = .default
    ) -> [URL] {
        remove(in: directory, fileManager: fileManager) { entry, modified in
            isSweepable(entry.lastPathComponent) && now.timeIntervalSince(modified) > staleAge
        }
    }

    /// Deletes the staging files belonging to `videoID`, immediately and with no age
    /// guard (see the file header for why neither is a lapse).
    ///
    /// - Parameters:
    ///   - videoID: The canonical 11-character id whose `[<id>]` marker selects the
    ///     files. Nothing without that marker is ever considered.
    ///   - directory: The staging directory, and ONLY ever that.
    ///   - scope: How much of the row's footprint to reclaim; see
    ///     ``DownloadStagingPurgeScope``.
    /// - Returns: The URLs actually deleted, for evidence and logging.
    @discardableResult
    public static func purgeArtifacts(
        ofVideoID videoID: String,
        in directory: URL,
        scope: DownloadStagingPurgeScope,
        fileManager: FileManager = .default
    ) -> [URL] {
        remove(in: directory, fileManager: fileManager) { entry, _ in
            isArtifact(entry.lastPathComponent, ofVideoID: videoID, scope: scope)
        }
    }

    /// Deletes every regular file DIRECTLY inside `directory` that `shouldRemove`
    /// accepts, and reports what actually went.
    ///
    /// Never recurses, never descends the directory's own packages, and never removes
    /// a directory — so a stray folder named like a leftover cannot take its contents
    /// with it. A file that cannot be deleted is skipped rather than reported.
    private static func remove(
        in directory: URL,
        fileManager: FileManager,
        where shouldRemove: (URL, Date) -> Bool
    ) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
        ) else {
            return []
        }
        var removed: [URL] = []
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  shouldRemove(entry, modified)
            else { continue }
            do {
                try fileManager.removeItem(at: entry)
            } catch {
                continue
            }
            removed.append(entry)
        }
        return removed
    }

    /// Whether `fileName` ends in `suffix` with at least one character before it.
    private static func hasStem(_ fileName: String, before suffix: String) -> Bool {
        fileName.hasSuffix(suffix) && fileName.count > suffix.count
    }

    /// Whether `infix` appears in `fileName` with at least one character on each side.
    private static func hasSurroundedInfix(_ infix: String, in fileName: String) -> Bool {
        guard let range = fileName.range(of: infix) else { return false }
        return range.lowerBound > fileName.startIndex && range.upperBound < fileName.endIndex
    }
}
