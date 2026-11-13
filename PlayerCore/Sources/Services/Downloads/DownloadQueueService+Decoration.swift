// DownloadQueueService+Decoration — the paste-time title/uploader/thumbnail fill.
//
// A pasted link is an 11-character id and nothing else. Until the driver reaches that
// row and spends a `-J` spawn on it, the queue can only show the id — so a fifty-link
// paste is fifty rows of gibberish that resolve one at a time over several minutes.
// This extension closes that gap with ONE keyless HTTP lookup per waiting row.
//
// ── DECORATIVE MEANS: NEVER BLOCKING, NEVER AUTHORITATIVE, NEVER A SPAWN ─────
//
// * Not blocking. `append()` fires these and returns; `EnqueueOutcome` is built from
//   the membership decision alone and never waits on a lookup. A lookup that never
//   answers costs the paste nothing.
// * Not authoritative. `-J` at dequeue is the source of truth for every field. This
//   writes ONLY into fields that are still `nil`, and `enrich(itemID:using:)`
//   (`+Driver.swift`) later overwrites what it wrote — but only with its own NON-nil
//   values, because every `YtDlpInfoPayload` field is Optional and an unqualified
//   overwrite would blank a title the person has already been reading. The two halves
//   of that rule live in two files and are both load-bearing; neither works alone.
// * Not a spawn. `yt-dlp` is never launched at paste time. The only egress is
//   ``OEmbedFetching``, whose sole production conformer is the one file
//   `scripts/check-downloader-boundary.sh` permits to transport.
//
// ── PENDING ROWS ONLY, AND THE ANTI-RESURRECTION GUARD ──────────────────────
//
// A lookup is fired only for a row that is still WAITING, and applied only to a row
// that is still waiting when the answer lands. Both halves matter:
//
//   * An ACTIVE row is already having `-J` fetched for it, so decorating it would
//     spend a request on a field that is about to be overwritten anyway.
//   * A row that was removed, cancelled, or dequeued while its own lookup was in
//     flight must not be written back — least of all re-added. `applyDecoration`
//     addresses `pending` BY ID and simply returns when the id is gone, which is the
//     same membership test `publishProgress(_:for:)` uses on the active side.
//
// A playlist expansion arrives pre-titled from the flat `-J` listing it was expanded
// from (`expandPlaylists`, `+Driver.swift`), so those rows fail the `title == nil`
// test and cost no requests at all.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

extension DownloadQueueService {
    /// Fires one decorative lookup for each of `items` that is still pending and still
    /// has no title.
    func decoratePendingRows(_ items: [DownloadItem]) {
        guard let oEmbedFetcher else { return }
        let waiting = Set(pending.map(\.id))
        for item in items where item.title == nil && waiting.contains(item.id) {
            decorationWork[item.id] = Task { [weak self] in
                let payload = await oEmbedFetcher.fetch(videoID: item.canonicalVideoID)
                self?.applyDecoration(payload, to: item.id)
            }
        }
    }

    /// Fills the still-empty descriptive fields of the PENDING row `itemID`, then
    /// republishes the snapshot — or does nothing at all.
    ///
    /// Every write is conditional on the field being `nil`, so a decoration can only
    /// ever add. The two `guard`s are also the only things standing between a late
    /// answer and a row that has moved on, so BOTH exits are silent: a lookup that told
    /// us nothing, and a row that has departed, must each cost the queue list zero
    /// passes. `@Observable` consumers invalidate on same-value writes, so an
    /// unconditional publication here would be a re-render per unanswered lookup.
    func applyDecoration(_ payload: OEmbedPayload?, to itemID: UUID) {
        decorationWork[itemID] = nil
        guard let payload, let index = pending.firstIndex(where: { $0.id == itemID }) else { return }
        if pending[index].title == nil { pending[index].title = payload.title }
        if pending[index].uploader == nil, let author = payload.authorName {
            pending[index].uploader = author
        }
        if pending[index].thumbnailURL == nil, let thumbnail = payload.thumbnailURL {
            pending[index].thumbnailURL = thumbnail
        }
        emitQueueChanged()
    }

    /// Drops every outstanding decorative lookup.
    ///
    /// Called by `cancelAll()` for the reason it already cancels
    /// ``playlistExpansionWork``: these belong to no in-flight row, so no per-item
    /// cancel can reach them, and a queue the person has just emptied should not keep
    /// asking the network about videos that are no longer in it.
    func cancelDecorations() {
        for work in decorationWork.values {
            work.cancel()
        }
        decorationWork.removeAll()
    }
}
