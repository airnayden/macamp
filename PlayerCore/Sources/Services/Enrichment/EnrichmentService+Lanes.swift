// EnrichmentService+Lanes — the two-lane page driver.
//
// A page is worked by TWO lanes running concurrently:
//
//   SERIAL lane   — every step that queues behind the ONE shared MusicBrainz
//                   rate limiter: the metadata lookup, the composer follow-up,
//                   and the cache-gated info prefetch (``MusicBrainzInfoClient``
//                   awaits the same limiter as ``MusicBrainzClient``). Running
//                   these concurrently would buy nothing — the limiter paces
//                   them to ≥1s apart regardless — so they stay strictly
//                   one-at-a-time and the ≥1s spacing stays easy to reason about.
//
//   PARALLEL lane — the LRCLIB lyrics fetch, which hits a different host behind
//                   no shared limiter. Up to ``lyricsLaneConcurrency`` in flight.
//
// The serial lane classifies each track and hands it off: a track that is
// metadata-complete AND already info-cached needs no rate-limited work at all and
// goes straight to the lyrics lane; every other track is handed over only after
// its rate-limited work finishes. So `progress.completed` advances exactly once
// per track — when its lyrics fetch returns — and pause gates new work in both
// lanes while in-flight work drains.
//
// Everything here is `@MainActor` (the service is). That is what makes the
// overlap safe AND real: each lane suspends at its `await`, releasing the main
// actor, so four lyrics requests and one MusicBrainz request are genuinely in
// flight together while no state mutation ever races.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Persistence

public extension EnrichmentService {
    /// Lyrics fetches allowed in flight at once.
    static let lyricsLaneConcurrency = 4
}

extension EnrichmentService {
    func run() async {
        await beginPass(total: presentTrackCount())
        var lastID: Int64?
        while !Task.isCancelled {
            await waitWhilePaused()
            if Task.isCancelled { break }
            let page = await nextPage(afterID: lastID)
            guard !page.isEmpty else { break }
            await processPage(page)
            lastID = page.last?.id
            guard lastID != nil else { break }
        }
        finish()
    }
}

private extension EnrichmentService {
    func processPage(_ page: [TrackRecord]) async {
        let (lyricsJobs, handOff) = AsyncStream<TrackRecord>.makeStream()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                await runLyricsLane(lyricsJobs)
            }
            await runSerialLane(page, handOff: handOff)
            handOff.finish()
            await group.waitForAll()
        }
    }

    /// Walks the page one track at a time, running the rate-limited work for the
    /// tracks that need it and handing every track to the lyrics lane.
    func runSerialLane(_ page: [TrackRecord], handOff: AsyncStream<TrackRecord>.Continuation) async {
        for track in page {
            if Task.isCancelled { return }
            await waitWhilePaused()
            if Task.isCancelled { return }
            guard track.availability == .present, track.id != nil else {
                completeOne()
                continue
            }
            beginTrack(track)
            guard await needsSerialLane(track) else {
                handOff.yield(track)
                continue
            }
            let enriched = await runRateLimitedWork(for: track)
            handOff.yield(enriched)
        }
    }

    /// Drains `jobs`, keeping at most ``lyricsLaneConcurrency`` fetches in flight
    /// and advancing `progress` as each one lands.
    func runLyricsLane(_ jobs: AsyncStream<TrackRecord>) async {
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for await track in jobs {
                if Task.isCancelled { break }
                await waitWhilePaused()
                if Task.isCancelled { break }
                if inFlight == Self.lyricsLaneConcurrency {
                    _ = await group.next()
                    inFlight -= 1
                }
                group.addTask { [self] in
                    await runLyricsWork(for: track)
                }
                inFlight += 1
            }
            await group.waitForAll()
        }
    }
}
