// Coverage of `OEmbedConcurrencyGate` — the ≤4 window every oEmbed lookup passes
// through.
//
// ── WHY EVERY ASSERTION IS `==`, NEVER `<=` ──────────────────────────────────
//
// This plan has now recorded five ways a concurrency-adjacent guard can pass while
// measuring nothing, and the cheapest of them is a `<=` bound satisfied by a peak
// of ZERO. So the window tests assert the peak EXACTLY: `== 4` fails both a broken
// gate that admits five and a broken harness where nothing ever overlapped. Each
// one is paired with a completion count, so "bounded" can never be achieved by
// dropping work.
//
// The capacity-2 case exists for the same reason at the other end: a gate that
// ignored its `capacity` argument and hardcoded four would satisfy the ≤4 test
// perfectly.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

@Suite("oEmbed concurrency window")
struct OEmbedConcurrencyWindowTests {
    /// Long enough that tasks launched together genuinely overlap (task start-up
    /// is microseconds — three orders of magnitude below this), short enough that
    /// the suite stays quick.
    static let latency = Duration.milliseconds(80)

    /// An 11-character base64url id, so the fake's table keys look like the
    /// production ones. Zero-padded, so a two-digit index does not change length.
    static func videoID(_ index: Int) -> String {
        "oEmbedVid" + String(format: "%02d", index)
    }

    static func thumbnailURL(_ index: Int) throws -> URL {
        try #require(URL(string: "https://i.ytimg.com/vi/\(videoID(index))/hqdefault.jpg"))
    }

    static func fetcher(count: Int) -> FakeOEmbedFetcher {
        var payloads: [String: OEmbedPayload] = [:]
        for index in 0 ..< count {
            payloads[videoID(index)] = OEmbedPayload(title: "Title \(index)")
        }
        return FakeOEmbedFetcher(payloads: payloads, latency: latency)
    }

    /// Runs `count` gated lookups at once and answers how many produced a payload.
    static func drive(
        count: Int,
        gate: OEmbedConcurrencyGate,
        fetcher: FakeOEmbedFetcher
    ) async -> Int {
        await withTaskGroup(of: Bool.self) { group in
            for index in 0 ..< count {
                let identifier = videoID(index)
                group.addTask {
                    await gate.withPermit { await fetcher.fetch(videoID: identifier) } != nil
                }
            }
            var answered = 0
            for await produced in group where produced {
                answered += 1
            }
            return answered
        }
    }

    // MARK: - The shipped window

    /// The acceptance criterion, literally: five requests through the fake, never
    /// more than four in flight — and, because a peak of zero would satisfy that
    /// vacuously, EXACTLY four.
    @Test("five lookups at once occupy exactly four slots, and all five answer")
    func fiveLookupsFillExactlyFourSlots() async {
        let fetcher = Self.fetcher(count: 5)
        let gate = OEmbedConcurrencyGate()
        let answered = await Self.drive(count: 5, gate: gate, fetcher: fetcher)

        #expect(fetcher.maxObservedConcurrency == 4)
        #expect(fetcher.fetchCallCount == 5)
        #expect(answered == 5)
        #expect(Set(fetcher.requestedVideoIDs).count == 5)
    }

    /// A wider burst must not widen the window. Twelve at once still peaks at four.
    @Test("a twelve-link paste still peaks at four")
    func aLargerBurstStillPeaksAtFour() async {
        let fetcher = Self.fetcher(count: 12)
        let gate = OEmbedConcurrencyGate()
        let answered = await Self.drive(count: 12, gate: gate, fetcher: fetcher)

        #expect(fetcher.maxObservedConcurrency == 4)
        #expect(answered == 12)
    }

    /// The capacity argument is honoured rather than decorative — a gate that
    /// hardcoded four would pass every test above and fail this one.
    @Test("capacity is respected, not hardcoded", arguments: [1, 2, 3])
    func capacityIsRespected(_ capacity: Int) async {
        let fetcher = Self.fetcher(count: 5)
        let gate = OEmbedConcurrencyGate(capacity: capacity)
        let answered = await Self.drive(count: 5, gate: gate, fetcher: fetcher)

        #expect(fetcher.maxObservedConcurrency == capacity)
        #expect(answered == 5)
    }

    /// A nonsensical capacity must still admit somebody: clamping to one is what
    /// stops a mis-wired composition root from hanging every paste for ever.
    @Test("a zero or negative capacity clamps to one rather than admitting nobody")
    func aNonsensicalCapacityClampsToOne() async {
        let fetcher = Self.fetcher(count: 3)
        let gate = OEmbedConcurrencyGate(capacity: 0)
        let answered = await Self.drive(count: 3, gate: gate, fetcher: fetcher)

        #expect(fetcher.maxObservedConcurrency == 1)
        #expect(answered == 3)
    }

    // MARK: - The window bounds lookups, not lookups-of-one-kind

    /// Metadata and thumbnail calls share the window: eight mixed lookups still
    /// peak at four. A gate applied to only one of the two methods would report a
    /// peak of five here (four metadata plus a thumbnail slipping past).
    @Test("thumbnail fetches occupy the same four slots as metadata fetches")
    func thumbnailsShareTheWindow() async throws {
        let thumbnailURLs = try (0 ..< 4).map { try Self.thumbnailURL($0) }
        var thumbnails: [URL: Data] = [:]
        for url in thumbnailURLs {
            thumbnails[url] = Data([0xFF, 0xD8])
        }
        var payloads: [String: OEmbedPayload] = [:]
        for index in 0 ..< 4 {
            payloads[Self.videoID(index)] = OEmbedPayload(title: "Title \(index)")
        }
        let fetcher = FakeOEmbedFetcher(payloads: payloads, thumbnails: thumbnails, latency: Self.latency)
        let gate = OEmbedConcurrencyGate()

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 4 {
                let identifier = Self.videoID(index)
                group.addTask { _ = await gate.withPermit { await fetcher.fetch(videoID: identifier) } }
            }
            for url in thumbnailURLs {
                group.addTask { _ = await gate.withPermit { await fetcher.fetchThumbnail(url: url) } }
            }
        }

        #expect(fetcher.maxObservedConcurrency == 4)
        #expect(fetcher.fetchCallCount == 4)
        #expect(fetcher.fetchThumbnailCallCount == 4)
    }

    // MARK: - The permit ledger itself

    /// Serial reuse must not leak permits: after a full burst drains, the gate is
    /// as good as new. A `release()` that decremented instead of handing the
    /// permit over would slowly starve the window, and only a second burst can
    /// see it.
    @Test("a drained gate is reusable at full width")
    func aDrainedGateIsReusable() async {
        let gate = OEmbedConcurrencyGate()
        let first = Self.fetcher(count: 5)
        _ = await Self.drive(count: 5, gate: gate, fetcher: first)
        #expect(first.maxObservedConcurrency == 4)

        let second = Self.fetcher(count: 5)
        let answered = await Self.drive(count: 5, gate: gate, fetcher: second)
        #expect(second.maxObservedConcurrency == 4)
        #expect(answered == 5)
    }

    /// The gate is a window, not a filter: it returns whatever the body returned,
    /// including the `nil` an unknown id produces.
    @Test("the gate passes results through untouched, nil included")
    func theGatePassesResultsThrough() async {
        let fetcher = FakeOEmbedFetcher(payloads: ["knownVideo1": OEmbedPayload(title: "Known")])
        let gate = OEmbedConcurrencyGate()

        let known = await gate.withPermit { await fetcher.fetch(videoID: "knownVideo1") }
        let unknown = await gate.withPermit { await fetcher.fetch(videoID: "unknownVid1") }

        #expect(known?.title == "Known")
        #expect(unknown == nil)
    }
}
