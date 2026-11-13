// MusicBrainzRateLimiter — a shared, injectable request pacer for MusicBrainz.
//
// MusicBrainz rate-limits anonymous callers to ~1 request/second. Both
// ``MusicBrainzClient`` (tag lookup) and ``MusicBrainzInfoClient`` (narrative
// info + Wikipedia) talk to musicbrainz.org, so the SAME limiter instance is
// injected into both at the composition root — that way their requests share one
// 1-req/sec gate and never collectively exceed the etiquette limit. The info
// client also routes its Wikipedia requests through this limiter, so every
// outbound HTTP call it makes is paced by a single shared gate.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// Serialises requests so consecutive ones are spaced at least `minimumInterval`
/// apart (MusicBrainz anonymous-caller etiquette). A reference-type `actor`, so a
/// single instance shared between clients paces them collectively.
public actor MusicBrainzRateLimiter {
    private let minimumInterval: Duration
    private var nextSlot: ContinuousClock.Instant?

    /// Creates a limiter.
    ///
    /// - Parameter minimumInterval: minimum spacing between requests (defaults to
    ///   one second). Tests pass `.zero` to disable the sleep.
    public init(minimumInterval: Duration = .seconds(1)) {
        self.minimumInterval = minimumInterval
    }

    /// Reserves the next free time slot and sleeps until it is due. The
    /// reservation (read + write of `nextSlot`) runs synchronously inside the
    /// actor before the sole `await`, so concurrent callers queue deterministically
    /// — each waits one more interval than the last.
    public func awaitSlot() async {
        let now = ContinuousClock.now
        let slot = max(now, nextSlot ?? now)
        nextSlot = slot.advanced(by: minimumInterval)
        if slot > now {
            try? await Task.sleep(until: slot, clock: .continuous)
        }
    }
}
