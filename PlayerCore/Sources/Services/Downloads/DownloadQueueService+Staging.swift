// DownloadQueueService+Staging — what an interrupted row reclaims from the staging
// directory, and how much of it.
//
// Split out of `DownloadQueueService.swift` for the file-length budget, along the seam
// that file already had: it owns MEMBERSHIP and the seams, the driver owns EXECUTION,
// and this owns the staging FOOTPRINT. Nothing here reads the listener's destination
// folder — every path it can touch is inside the app-private staging directory.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

// MARK: - Staging hygiene

extension DownloadQueueService {
    /// Removes `item`'s leftovers from the staging directory.
    ///
    /// # Why this exists at all
    /// Interrupting a download during POST-PROCESSING leaves a partial output container
    /// — `Title [id].m4a`, valid but short. Retrying that video makes yt-dlp ADOPT it as
    /// already-post-processed: it tags it, moves it to the destination, and exits 0, so
    /// MacAMP reports a success and imports a truncated file. Deleting the row's own
    /// artifacts at the moment of interruption is the precise fix — it removes the file
    /// a retry would adopt, without telling the engine to overwrite anything (a
    /// COMPLETE file being adopted is correct behaviour and must keep working).
    ///
    /// Scoped to the marker `[<canonicalVideoID>]`, so a purge can only ever touch the
    /// files yt-dlp wrote for this row, in the app-private staging directory. The
    /// listener's destination folder is never read here.
    ///
    /// # The two live scopes
    /// `.allArtifacts` is what a CANCEL asks for (`requestCancellation(of:)`): the row is
    /// dropped and never comes back, so its `.part` is stranded bytes.
    /// `.adoptableOutputs` is what a FAILURE asks for (the driver's generic-failure
    /// branch): a failure is the state a person retries most, so the container a retry
    /// would wrongly adopt goes while the resumable `.part` stays.
    func purgeStagingArtifacts(of item: DownloadItem, scope: DownloadStagingPurgeScope) {
        DownloadStagingSweeper.purgeArtifacts(
            ofVideoID: item.canonicalVideoID,
            in: stagingDirectory,
            scope: scope
        )
    }

    /// Removes one row's ffmpeg conversion progress file.
    ///
    /// Narrower than either purge scope on purpose, because it is called on paths where
    /// those would be wrong. It runs BEFORE a spawn — a previous attempt's file must not
    /// be read by this attempt's poller in the moment before ffmpeg truncates it — and
    /// again after a row COMPLETES, where no purge runs at all: a finished download is
    /// not an interruption, so nothing else would ever reclaim this file and the staging
    /// directory would grow by one of them per successful download until the next launch
    /// sweep aged it out. Measured on a real run (`.omo/evidence/dlv2-09.txt` §9).
    ///
    /// Cancel and failure keep going through the purge scopes, which already cover it.
    func discardConversionProgress(ofVideoID videoID: String) {
        let progressFile = YtDlpCommandBuilder.ffProgressURL(forVideoID: videoID, in: stagingDirectory)
        try? FileManager.default.removeItem(at: progressFile)
    }
}
