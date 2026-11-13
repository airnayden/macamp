// Snapshots terminal download attempts and writes them in settlement order.
import Foundation
import os
import Persistence

/// Appends one `downloadHistory` row per completed or failed download attempt.
///
/// Queue callbacks and the tail of the write chain are main-actor state.
@MainActor
public final class DownloadHistoryRecorder {
    private let history: any DownloadHistoryRepositoryProviding
    private let fallbackFormat: @Sendable () -> DownloadFormat
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let didRecord: @MainActor @Sendable () -> Void

    /// Tail of the serial write chain; awaiting it awaits everything before it.
    private var tail: Task<Void, Never>?

    public init(
        history: any DownloadHistoryRepositoryProviding,
        fallbackFormat: @escaping @Sendable () -> DownloadFormat,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current,
        didRecord: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.history = history
        self.fallbackFormat = fallbackFormat
        self.now = now
        self.timeZone = timeZone
        self.didRecord = didRecord
    }

    /// Records `item` — which finished at `fileURL` — as one row of download history.
    ///
    /// Returns immediately; the write is enqueued off-main. Use ``flushAndWait()``
    /// to await it.
    public func record(_ item: DownloadItem, at fileURL: URL) {
        append(makeEntry(from: item, filePath: fileURL.path))
    }

    public func recordFailure(_ item: DownloadItem, error: DownloadError) {
        let reason = String(localized: error.message)
        let detail = error.detail.map { String($0.prefix(512)) }
        append(makeEntry(
            from: item,
            filePath: "",
            failureReason: [reason, detail].compactMap(\.self).joined(separator: "\n")
        ))
    }

    private func append(_ entry: DownloadHistoryRecord) {
        let history = history
        let didRecord = didRecord
        enqueue {
            do {
                try await history.insert(entry)
                await didRecord()
            } catch {
                // History is a log, not a gate: a download that succeeded must not be
                // reported as failed because its bookkeeping row did not land. The
                // insert is one statement inside GRDB's own transaction, so a throw
                // leaves NO partial row behind — there is nothing to clean up here.
                Self.log.error("download history insert failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Awaits every write enqueued so far.
    public func flushAndWait() async {
        await tail?.value
    }
}

// MARK: - Composition

private extension DownloadHistoryRecorder {
    /// `nonisolated` because the insert's failure path runs inside the detached task,
    /// off the main actor. `Logger` is `Sendable`, so sharing it costs nothing.
    nonisolated static let log = Logger(subsystem: "si.macamp.MacAMP", category: "downloads-history")

    /// Builds a row from the settled item, stamping the capture instant.
    ///
    /// Every descriptive field comes from `item` and nothing is looked up: the row
    /// must still describe this download after the video is renamed, the channel is
    /// deleted, or the file is moved — the `playEvent` survivability precedent.
    ///
    /// `durationSeconds` widens the item's `Int?` to the column's `Double?` rather
    /// than the other way round, so an engine that later reports fractional seconds
    /// needs no migration.
    func makeEntry(from item: DownloadItem, filePath: String, failureReason: String? = nil) -> DownloadHistoryRecord {
        let capturedAt = now()
        let format = item.resolvedFormat ?? fallbackFormat()
        return DownloadHistoryRecord(
            id: UUID().uuidString,
            canonicalVideoID: item.canonicalVideoID,
            title: item.title,
            uploader: item.uploader,
            durationSeconds: item.durationSeconds.map(Double.init),
            filePath: filePath,
            audioFormat: format.audioFormat.rawValue,
            audioQuality: format.audioQuality.rawValue,
            sourceURL: item.sourceURL.absoluteString,
            downloadedAt: capturedAt.timeIntervalSince1970,
            utcOffsetSeconds: timeZone.secondsFromGMT(for: capturedAt),
            failureReason: failureReason
        )
    }

    /// Chains `work` behind everything already enqueued.
    ///
    /// Serial by construction, so history lands in finish order and
    /// ``flushAndWait()`` only has to await the tail. Detached because the work hits
    /// the database and must never run on the main actor. `PlayEventRecorder`'s
    /// precedent, for the same two reasons.
    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task.detached(priority: .utility) {
            await previous?.value
            await work()
        }
    }
}
