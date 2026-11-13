// LibraryChatViewModel+Enrichment — filling in a landed suggestion's video link
// without disturbing the row it belongs to.
//
// Split out of ``LibraryChatViewModel`` so that file holds the turn loop alone; the
// members this reaches for are internal rather than `private` for exactly that reason,
// the same arrangement `AssistantViewModel+Ladder.swift` records.
//
// ── THE ROW IS REBUILT, NOT MUTATED ──────────────────────────────────────────
//
// ``LibraryChatMessage`` is a value type whose every field is a `let`, and the
// suggestions live one level deeper still, inside
// ``AssistantChatEvent/toolResult(name:summary:resultCount:rows:suggestions:)``. So
// "add a link" is necessarily a rebuild of the event, of the message, and of the slot
// it sits in. The rebuild carries the message's EXISTING `id` and writes back at the
// index that id is found at — never appends, never re-orders, never re-identifies — so
// `messages.count` and every `id` in it are invariant across enrichment. That is not
// tidiness: `LibraryChatMessage` is `Identifiable` by a minted UUID precisely so
// SwiftUI keeps a row it has already drawn, and a fresh id would re-animate a
// transcript the listener is in the middle of reading.
//
// ── AN ENRICHER MAY CONTRIBUTE EXACTLY ONE FIELD ─────────────────────────────
//
// It is handed the suggestions in event order and answers in the same order. What
// comes back is merged POSITIONALLY and field by field: `title` and `artist` are taken
// from the ORIGINAL every time and only ``AssistantChatSuggestion/videoURL`` is
// adopted. So an enricher cannot rewrite what the listener asked for, cannot re-order
// the list and cannot add a line — the transcript's words stay the tier's.
//
// An answer of a different LENGTH is discarded whole, because a positional merge over
// a list that changed size merges the wrong pairs. "Answered fewer" and "failed" are
// deliberately the same outcome: a resolver that gave up leaves the row exactly as it
// landed rather than half-linked.
//
// ── AND NOTHING IS WRITTEN WHEN NOTHING CHANGED ──────────────────────────────
//
// `@Observable` publishes on same-value writes, so an enrichment that resolved no link
// at all returns without touching `messages` instead of writing an identical
// transcript back over itself and redrawing the pane for it.
//
// This file imports only Foundation and Services; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant). It names no transport symbol either — the
// resolver is injected from above, because `PlayerCore/Sources/ViewModels` is a
// scanned network-boundary target.
import Foundation
import Services

extension LibraryChatViewModel {
    /// Starts enriching `message`, if there is both something and someone to enrich.
    ///
    /// The task re-reads ``generation`` after its `await` and drops everything when it
    /// has moved, so an answer to a conversation that has since been reset writes
    /// nothing — the same guard an in-flight turn carries, for the same reason.
    func scheduleEnrichment(of message: LibraryChatMessage, generation turnGeneration: Int) {
        guard let suggestionEnricher else { return }
        let originals = SuggestionEnrichment.suggestions(in: message.events)
        guard !originals.isEmpty else { return }
        let identifier = message.id
        enrichments[identifier] = Task { @MainActor [weak self] in
            let answer = await suggestionEnricher(originals)
            guard let self else { return }
            enrichments[identifier] = nil
            guard turnGeneration == generation else { return }
            apply(answer, over: originals, toRowWith: identifier)
        }
    }

    /// Cancels every enrichment in flight. See ``reset()`` and ``cancelInFlight()``.
    ///
    /// Cancellation alone is not the guard — an enricher is free not to observe it —
    /// which is why the task re-checks the generation before it writes.
    func cancelEnrichments() {
        for task in enrichments.values {
            task.cancel()
        }
        enrichments.removeAll()
    }

    /// Merges `answer` over `originals` and writes the result onto the row `identifier`
    /// names, or returns having written nothing.
    private func apply(
        _ answer: [AssistantChatSuggestion],
        over originals: [AssistantChatSuggestion],
        toRowWith identifier: UUID
    ) {
        let merged = SuggestionEnrichment.merged(originals, with: answer)
        guard merged != originals, let row = messages.first(where: { $0.id == identifier }) else { return }
        replaceMessage(id: identifier, with: SuggestionEnrichment.rebuilt(row, with: merged))
    }
}

/// The pure half: reading suggestions out of a turn, merging an answer over them, and
/// writing them back.
///
/// File-scoped and static so each rule above is a function over value types that a
/// test can drive directly, rather than a step buried inside a task.
private enum SuggestionEnrichment {
    /// Every suggestion in `events`, flattened in event order — the order an enricher
    /// is handed them in and must answer in.
    static func suggestions(in events: [AssistantChatEvent]) -> [AssistantChatSuggestion] {
        events.flatMap { event -> [AssistantChatSuggestion] in
            guard case let .toolResult(_, _, _, _, carried) = event else { return [] }
            return carried
        }
    }

    /// `originals`, each taking its video link from the answer at its own position —
    /// or `originals` untouched when the answer is the wrong length.
    static func merged(
        _ originals: [AssistantChatSuggestion],
        with answer: [AssistantChatSuggestion]
    ) -> [AssistantChatSuggestion] {
        guard answer.count == originals.count else { return originals }
        return zip(originals, answer).map { original, resolved in
            AssistantChatSuggestion(
                title: original.title,
                artist: original.artist,
                videoURL: resolved.videoURL
            )
        }
    }

    /// `row` with `suggestions` distributed back across its events, keeping its id.
    ///
    /// Field by field, so a field this rebuild forgets is silently WIPED rather than
    /// preserved — and enrichment always rewrites exactly the suggestion-bearing row,
    /// which is the same row an append target lands on. Both target fields are
    /// therefore carried through explicitly; defaulting them would be the normal
    /// ordering, not an edge case.
    static func rebuilt(
        _ row: LibraryChatMessage,
        with suggestions: [AssistantChatSuggestion]
    ) -> LibraryChatMessage {
        LibraryChatMessage(
            id: row.id,
            role: row.role,
            text: row.text,
            events: replacing(row.events, with: suggestions),
            proposalIds: row.proposalIds,
            isTruncated: row.isTruncated,
            failure: row.failure,
            appendTarget: row.appendTarget,
            appendProfileId: row.appendProfileId
        )
    }

    /// `events` with each result's suggestions replaced by the next slice of
    /// `suggestions`.
    ///
    /// The slices are cut to the very counts ``suggestions(in:)`` read them at, and the
    /// total was checked before the merge, so the walk consumes the list exactly.
    private static func replacing(
        _ events: [AssistantChatEvent],
        with suggestions: [AssistantChatSuggestion]
    ) -> [AssistantChatEvent] {
        var remaining = suggestions[...]
        return events.map { event -> AssistantChatEvent in
            guard case let .toolResult(name, summary, resultCount, rows, carried) = event,
                  !carried.isEmpty
            else {
                return event
            }
            let slice = remaining.prefix(carried.count)
            remaining = remaining.dropFirst(carried.count)
            return .toolResult(
                name: name,
                summary: summary,
                resultCount: resultCount,
                rows: rows,
                suggestions: Array(slice)
            )
        }
    }
}
