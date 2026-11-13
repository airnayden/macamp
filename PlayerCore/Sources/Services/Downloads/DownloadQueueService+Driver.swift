// DownloadQueueService+Driver — the slot pump and the per-row driver behind it.
//
// Split from `DownloadQueueService.swift` for the file-length budget, along the seam the
// two halves already had: that file owns MEMBERSHIP and the seams, this one owns
// EXECUTION. Nothing here mutates the pending array except through the helpers over there.
//
// # One driver per row, one pump for all of them
// Each in-flight row gets its own `Task` in `drivers`, keyed by row id, running the
// ladder below independently of its siblings. `pump()` is the only thing that creates
// them, and it is re-entered by `append()` and by every row that settles — so the
// mutation it performs must be synchronous, which is the invariant documented on it.
//
// # Order of operations at dequeue, and why it is that order
// 1. Destination writability — the cheapest check and the one whose failure must not cost
//    a network round-trip. Failing here leaves the row `.failed(.destinationUnavailable)`
//    and the driver moves on: one broken folder must never drain the queue.
// 2. Tool resolution.
// 3. Rich metadata (`-J`), fetched LAZILY, for THIS row only. Prefetching N rows up front
//    would fire N requests for a queue the person may cancel after the first.
// 4. The transfer.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// Where the engine and its helpers live, resolved once per download.
struct DownloadToolContext {
    let ytDlpURL: URL
    let toolsDirectory: URL
}

// MARK: - Slot pump

extension DownloadQueueService {
    /// Fills every free slot from `pending`, then emits ONE snapshot for the whole pass.
    ///
    /// # Why the mutation must be synchronous
    /// Dequeue, append and driver registration all happen BEFORE any suspension point,
    /// inside the loop. `append()` and every settle re-enter this function, and the only
    /// thing stopping two of those passes from filling the same slot twice is that
    /// `active.count` has already grown by the time the second one reads it. Introduce an
    /// `await` between `dequeueNext()` and `active.append(item)` and the count is stale
    /// for the length of that suspension — which is precisely long enough to overspawn.
    ///
    /// # Why one snapshot, not one per row
    /// Three slots filling is ONE membership change from the list's point of view.
    /// Emitting per dequeue would re-render the queue three times for a single pass and
    /// show two intermediate states nobody asked for.
    func pump() {
        var started = false
        while !isPaused, active.count < concurrencyLimit(), let item = dequeueNext() {
            active.append(item)
            drivers[item.id] = Task { [weak self] in
                await self?.runItem(item)
            }
            started = true
        }
        guard started else { return }
        emitQueueChanged()
    }

    /// How many slots the pump may fill, clamped into the supported range.
    ///
    /// Read at every refill rather than captured once, so a listener raising or lowering
    /// the setting mid-queue applies to the next row picked up. Lowering it below the
    /// number already running never interrupts anything: extant transfers finish and the
    /// pump simply stops refilling until the count falls back under the new limit.
    func concurrencyLimit() -> Int {
        min(max(maxConcurrent(), 1), DownloadQueueLimits.maxConcurrentDownloads)
    }

    /// Runs one row to its terminal state, retires its driver, and refills the slot.
    ///
    /// `token` is an IMMUTABLE handle from here on — only `id` and `canonicalVideoID` may
    /// be read from it. Everything mutable lives in ``DownloadQueueService/active``.
    private func runItem(_ token: DownloadItem) async {
        let outcome = await run(token)
        // Retired BEFORE the outcome is applied, not after. `applyOutcome` settles the
        // row — which frees a slot and fires the row seam, and an observer of that seam
        // that enqueues re-enters `pump()` synchronously. Leaving this entry in place
        // across that window would let `drivers` hold one more task than there are
        // slots, and the driver is done driving by now: dropping the handle does not
        // cancel a task that is already executing.
        drivers[token.id] = nil
        applyOutcome(outcome, for: token.id)
        pump()
    }

    private func dequeueNext() -> DownloadItem? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Runs one row end to end and reports how it ended.
    private func run(_ token: DownloadItem) async -> DownloadOutcome {
        let destination = destinationDirectory()
        guard isDirectoryWritable(destination) else { return .failed(.destinationUnavailable) }
        guard let tools = await resolveTools() else { return .failed(.toolMissing) }
        guard !cancellationRequested.contains(token.id) else { return .failed(.cancelled) }

        publishProgress(.fetchingMetadata, for: token.id)
        await enrich(itemID: token.id, using: tools.ytDlpURL)
        guard !cancellationRequested.contains(token.id) else { return .failed(.cancelled) }

        let format = downloadFormat()
        stampResolvedFormat(format, for: token.id)
        let request = YtDlpDownloadRequest(
            videoID: token.canonicalVideoID,
            format: format,
            downloadsDirectory: destination,
            stagingDirectory: stagingDirectory,
            toolsDirectory: tools.toolsDirectory
        )
        guard let arguments = YtDlpCommandBuilder.downloadArguments(for: request) else {
            return .failed(.invalidArguments)
        }
        return await transfer(
            tool: tools.ytDlpURL,
            arguments: arguments,
            itemID: token.id,
            conversion: conversionProgressSource(for: token)
        )
    }

    /// The conversion poller's inputs for this row, with any stale progress file cleared.
    ///
    /// The duration is read from ``DownloadQueueService/active`` HERE — after `enrich`
    /// has landed and immediately before the transfer spawns — and travels into the
    /// detached task as a plain value. `nil` when the `-J` prefetch failed, which the
    /// tailer turns into a permanently indeterminate bar rather than a guess.
    ///
    /// The file is discarded first because a previous attempt at this same video can have
    /// left one behind: ffmpeg truncates it when it opens it, but the poller's first read
    /// could otherwise land in the window before that and report another run's timeline.
    private func conversionProgressSource(for token: DownloadItem) -> ConversionProgressSource {
        discardConversionProgress(ofVideoID: token.canonicalVideoID)
        let duration = active.first(where: { $0.id == token.id })?.durationSeconds
        return ConversionProgressSource(
            progressFile: YtDlpCommandBuilder.ffProgressURL(
                forVideoID: token.canonicalVideoID,
                in: stagingDirectory
            ),
            durationSeconds: duration.map(Double.init)
        )
    }

    /// Records the format this row was dequeued with, into `active`.
    ///
    /// A row that has already departed is skipped. The snapshot is republished because
    /// the stamp is the last thing to land on an active row before its transfer starts —
    /// without it, `resolvedFormat` would only ever be observable on the finished row
    /// handed to `onItemFinished`, never on the row the queue list is rendering.
    private func stampResolvedFormat(_ format: DownloadFormat, for itemID: UUID) {
        guard let index = active.firstIndex(where: { $0.id == itemID }),
              active[index].resolvedFormat != format
        else {
            return
        }
        active[index].resolvedFormat = format
        emitQueueChanged()
    }

    /// Resolves the engine and ffmpeg locations, or `nil` when the tools are unavailable.
    private func resolveTools() async -> DownloadToolContext? {
        guard let ytDlpURL = try? await toolProvider.ytDlpURL,
              let toolsDirectory = try? await toolProvider.ffmpegDirectoryURL
        else {
            return nil
        }
        return DownloadToolContext(ytDlpURL: ytDlpURL, toolsDirectory: toolsDirectory)
    }
}

// MARK: - Transfer

private extension DownloadQueueService {
    /// Spawns the download off-main and maps its termination through the production map.
    func transfer(
        tool: URL,
        arguments: [String],
        itemID: UUID,
        conversion: ConversionProgressSource
    ) async -> DownloadOutcome {
        let runner = processRunner
        let publish: @Sendable (DownloadState) async -> Void = { [weak self] state in
            await self?.publishProgress(state, for: itemID)
        }
        let work = Task.detached(priority: .utility) {
            try await DownloadEngineRun.transfer(
                runner: runner,
                tool: tool,
                arguments: arguments,
                conversion: conversion,
                publish: publish
            )
        }
        transferWork[itemID] = work
        defer { transferWork[itemID] = nil }
        do {
            let result = try await work.value
            // No termination event at all is the documented cancellation shape.
            guard let termination = result.termination else { return .failed(.cancelled) }
            return YtDlpProgressParser.outcome(
                of: termination,
                filePath: result.filePath,
                lastErrorLine: result.lastErrorLine,
                cancellationRequested: cancellationRequested.contains(itemID)
            )
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch let error as DownloadError {
            return .failed(error)
        } catch {
            return .failed(.downloadFailed(detail: String(describing: error)))
        }
    }
}

// MARK: - Metadata (lazy, at dequeue)

extension DownloadQueueService {
    /// Fills ONE in-flight row's descriptive fields in place, in `active`, by id.
    ///
    /// Metadata is DECORATIVE: a prefetch that fails, is cancelled, or returns something
    /// undecodable leaves the row as it was and the download proceeds — the transfer needs
    /// only the canonical id, which the row already carries.
    ///
    /// Both lookups go through `active` by id, and the second one is not redundant: the
    /// row may have settled or been cancelled while its own prefetch was in flight, and a
    /// write addressed by INDEX rather than id would land on whichever row inherited that
    /// position — enriching a sibling with this row's title.
    ///
    /// # `-J` is authoritative, but only where it actually said something
    /// Every field of ``YtDlpInfoPayload`` is Optional, and the engine legitimately omits
    /// any of them. The row it is writing onto is NOT necessarily empty: the paste-time
    /// oEmbed decoration (`+Decoration.swift`) may have filled the title the person has
    /// been reading in the pending list for the last minute. So each field is written
    /// only when this payload carries one — an unqualified assignment would blank that
    /// title at the exact moment the download starts, which reads as the app losing
    /// information it had. Where `-J` DOES answer it still wins outright; that is what
    /// "authoritative" means here, and it is why these are overwrites rather than
    /// `nil`-guarded fills.
    private func enrich(itemID: UUID, using tool: URL) async {
        guard let item = active.first(where: { $0.id == itemID }),
              let watchURL = YouTubeURLNormalizer.canonicalURL(forVideoID: item.canonicalVideoID),
              let payload = await prefetch(tool: tool, url: watchURL, itemID: itemID),
              let index = active.firstIndex(where: { $0.id == itemID })
        else {
            return
        }
        if let title = payload.titleText { active[index].title = title }
        if let uploader = payload.uploaderName { active[index].uploader = uploader }
        if let duration = payload.durationSeconds { active[index].durationSeconds = duration }
        if let thumbnail = payload.thumbnailURL { active[index].thumbnailURL = thumbnail }
        emitQueueChanged()
    }

    /// Runs one `-J` prefetch off-main, tracked so a cancel can kill it mid-listing.
    ///
    /// `itemID` is `nil` for a PLAYLIST EXPANSION, which runs before its entries exist
    /// and so has no row to be keyed by; that one is tracked in its own slot instead.
    private func prefetch(tool: URL, url: URL, itemID: UUID? = nil) async -> YtDlpInfoPayload? {
        let runner = processRunner
        let work = Task.detached(priority: .utility) {
            try await DownloadEngineRun.info(runner: runner, tool: tool, url: url)
        }
        if let itemID { metadataWork[itemID] = work } else { playlistExpansionWork = work }
        defer {
            if let itemID { metadataWork[itemID] = nil } else { playlistExpansionWork = nil }
        }
        return try? await work.value
    }

    /// Expands every playlist URL in a paste into one HELD batch awaiting confirmation.
    ///
    /// Multiple playlist URLs in one paste are combined rather than having all but the
    /// first silently ignored: `EnqueueOutcome` carries one confirmation, and dropping
    /// links the person actually pasted would be a worse answer than one merged sheet.
    /// Entries are deduplicated across the whole batch, THEN capped — so the cap counts
    /// distinct videos, and `capped` reports that the paste really was longer.
    ///
    /// Each row is STAMPED from the flat listing's own fields. `--flat-playlist -J`
    /// already prints a title (and usually a channel) per entry, so a 500-entry playlist
    /// arrives fully titled for the price of the one listing that expanded it — no extra
    /// request, no extra spawn, and no paste-time decoration fired for any of them.
    func expandPlaylists(_ urls: [URL]) async -> EnqueueOutcome.PendingPlaylist? {
        guard !urls.isEmpty, let tool = try? await toolProvider.ytDlpURL else { return nil }
        var seen = Set<String>()
        var entries: [DownloadItem] = []
        for url in urls {
            guard let payload = await prefetch(tool: tool, url: url) else { continue }
            for entry in payload.videoEntries {
                guard seen.insert(entry.videoID).inserted,
                      let watchURL = YtDlpCommandBuilder.watchURL(forVideoID: entry.videoID)
                else {
                    continue
                }
                entries.append(DownloadItem(
                    canonicalVideoID: entry.videoID,
                    sourceURL: watchURL,
                    title: entry.title,
                    uploader: entry.uploaderName,
                    thumbnailURL: entry.thumbnailURL
                ))
            }
        }
        guard !entries.isEmpty else { return nil }
        let token = UUID()
        let held = Array(entries.prefix(DownloadQueueLimits.maxPlaylistExpansion))
        heldPlaylist = HeldPlaylist(token: token, items: held)
        return EnqueueOutcome.PendingPlaylist(
            token: token,
            count: held.count,
            capped: entries.count > DownloadQueueLimits.maxPlaylistExpansion
        )
    }
}

// MARK: - Outcome application

private extension DownloadQueueService {
    /// Applies a finished row's outcome.
    ///
    /// The row is re-read from ``DownloadQueueService/active`` rather than taken from the
    /// driver's own token, because that is where the `-J` enrichment and the format stamp
    /// landed while the transfer ran. `onItemFinished` carries THIS copy, so the fetched
    /// title and the container actually produced reach the import seam.
    func applyOutcome(_ outcome: DownloadOutcome, for itemID: UUID) {
        // The row may have been cancelled out from under the driver; a late outcome must
        // never resurrect it.
        guard var item = active.first(where: { $0.id == itemID }) else { return }
        switch outcome {
        case let .completed(filePath):
            // A success runs no purge — nothing was interrupted — so the conversion
            // progress file is reclaimed explicitly here or it survives until the launch
            // sweep ages it out, one per finished download.
            discardConversionProgress(ofVideoID: item.canonicalVideoID)
            let fileURL = URL(fileURLWithPath: filePath)
            item.state = .finished(fileURL: fileURL)
            settle(item)
            onItemFinished?(item, fileURL)
        case .failed(.cancelled):
            // Second purge, after the child is reaped. The first one runs at signal
            // time inside `requestCancellation(of:)`, while ffmpeg — a GRANDCHILD that
            // SIGTERM to yt-dlp does not reach — may still be finishing the container
            // that a retry would then adopt. Idempotent, so running twice costs nothing.
            purgeStagingArtifacts(of: item, scope: .allArtifacts)
            item.state = .cancelled
            settle(item)
        case let .failed(error):
            // `.alreadyDownloaded` lands here: a real terminal state with friendly copy,
            // and deliberately NO `onItemFinished` — no file was moved to import.
            //
            // A failure is the state a person retries most, so the adoptable container
            // goes; the resumable `.part` STAYS, because re-running after a transient
            // network error is exactly when resuming from it is worth the most.
            purgeStagingArtifacts(of: item, scope: .adoptableOutputs)
            item.state = .failed(error)
            settle(item)
            if error != .alreadyDownloaded {
                onItemFailed?(item, error)
            }
        }
    }

    /// Retires `item` from the queue, publishing its terminal state and the snapshot.
    ///
    /// Retiring the id from ``DownloadQueueService/cancellationRequested`` is part of
    /// retiring the row: ids are reused by nothing, but a set that only ever grows would
    /// pin one entry per cancelled row for the life of the process.
    func settle(_ item: DownloadItem) {
        active.removeAll { $0.id == item.id }
        cancellationRequested.remove(item.id)
        emitItemState(item.state, for: item.id)
        emitQueueChanged()
    }
}
