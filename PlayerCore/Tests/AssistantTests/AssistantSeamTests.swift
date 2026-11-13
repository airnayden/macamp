// AssistantSeamTests — the seam currency and the three protocol contracts.
//
// These prove the shapes todos 14-17 build on: that `PlaylistQuerySpec` normalizes
// and clamps by construction, that a generated name is bounded whatever a backend
// returns, that a digest window reduces to the narration budget deterministically,
// and that all three Fakes record and fail on demand.
import Foundation

// `SmartPlaylistRange` is re-exported through `PlaylistQuerySpec`'s public surface:
// the spec reuses the rule engine's own range type so a resolver has nothing to
// convert. Every consumer of the spec's bounds therefore imports `Persistence`,
// which each one already needs to build a `SmartPlaylistRules` anyway.
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@Suite("PlaylistQuerySpecShape")
struct PlaylistQuerySpecTests {
    @Test("An all-default spec is unconstrained and asks for the mix default count")
    func defaultsAreUnconstrained() {
        let spec = PlaylistQuerySpec()
        #expect(spec.isUnconstrained)
        #expect(spec.targetCount == MixSpec.defaultTargetCount)
        #expect(!spec.lowConfidence)
    }

    @Test("targetCount is clamped to the same window MixSpec uses")
    func targetCountIsClamped() {
        #expect(PlaylistQuerySpec(targetCount: 0).targetCount == 1)
        #expect(PlaylistQuerySpec(targetCount: -40).targetCount == 1)
        #expect(PlaylistQuerySpec(targetCount: 10000).targetCount == MixSpec.maxTargetCount)
        #expect(PlaylistQuerySpec(targetCount: 12).targetCount == 12)
    }

    @Test("Names are trimmed, emptied entries dropped, duplicates removed in order")
    func namesAreNormalizedInOrder() {
        let spec = PlaylistQuerySpec(
            genres: ["  Rock ", "rock", "", "   ", "Jazz", "ROCK"],
            seedArtists: ["Radiohead", "radiohead ", "Portishead"]
        )
        // Order-preserving, first occurrence wins, case-insensitive de-duplication:
        // the first genre a generator names is its most confident one, and a
        // `Set`-based pass would reorder it nondeterministically.
        #expect(spec.genres == ["Rock", "Jazz"])
        #expect(spec.seedArtists == ["Radiohead", "Portishead"])
    }

    @Test("Mood tags de-duplicate while preserving order")
    func moodTagsDeduplicate() {
        let spec = PlaylistQuerySpec(moodTags: [.energetic, .calm, .energetic, .bright])
        #expect(spec.moodTags == [.energetic, .calm, .bright])
    }

    @Test("Any single constraint makes a spec constrained")
    func anyConstraintCounts() {
        #expect(!PlaylistQuerySpec(genres: ["Rock"]).isUnconstrained)
        #expect(!PlaylistQuerySpec(yearRange: SmartPlaylistRange(lower: 1990, upper: 1999)).isUnconstrained)
        #expect(!PlaylistQuerySpec(moodTags: [.calm]).isUnconstrained)
        #expect(!PlaylistQuerySpec(tempoRange: SmartPlaylistRange(lower: 120)).isUnconstrained)
        #expect(!PlaylistQuerySpec(recency: .rediscovery).isUnconstrained)
        #expect(!PlaylistQuerySpec(seedArtists: ["Nujabes"]).isUnconstrained)
        // targetCount and lowConfidence are NOT constraints — they say how many and
        // how sure, not which tracks.
        #expect(PlaylistQuerySpec(targetCount: 7, lowConfidence: true).isUnconstrained)
    }

    @Test("A spec survives a JSON round trip")
    func roundTripsThroughJSON() throws {
        let spec = PlaylistQuerySpec(
            genres: ["Rock", "Jazz"],
            yearRange: SmartPlaylistRange(lower: 1990, upper: 1999),
            moodTags: [.energetic],
            tempoRange: SmartPlaylistRange(lower: 120, upper: nil),
            recency: .freshlyAdded,
            seedArtists: ["Portishead"],
            targetCount: 30,
            lowConfidence: true
        )
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(PlaylistQuerySpec.self, from: data)
        #expect(decoded == spec)
    }
}

@Suite("PlaylistNamingResultShape")
struct PlaylistNamingResultTests {
    @Test("A name is trimmed and capped at the seam's own limit")
    func nameIsBounded() {
        let long = String(repeating: "a", count: 200)
        let result = PlaylistNamingResult(name: "   \(long)   ")
        #expect(result.name.count == PlaylistNamingResult.maxNameLength)
        #expect(PlaylistNamingResult.maxNameLength == 60)
    }

    @Test("A blank description collapses to nil rather than an empty string")
    func blankDescriptionBecomesNil() {
        #expect(PlaylistNamingResult(name: "Mix", description: "   ").description == nil)
        #expect(PlaylistNamingResult(name: "Mix").description == nil)
        #expect(PlaylistNamingResult(name: "Mix", description: " Nice ").description == "Nice")
    }

    @Test("A narrative is trimmed")
    func narrativeIsTrimmed() {
        #expect(InsightNarrationResult(narrative: "  You listened a lot. ").narrative == "You listened a lot.")
    }
}

@Suite("InsightNarrationProjection")
struct InsightNarrationProjectionTests {
    private static func digest() -> ListeningWindowDigest {
        var hours = Array(repeating: 0, count: 24)
        hours[9] = 12
        hours[21] = 12 // tie with hour 9 — the earlier hour must win
        hours[3] = 4
        return ListeningWindowDigest(
            window: .last30Days,
            totalPlays: 40,
            totalListenedSeconds: 7200,
            topTracks: (1 ... 7).map { index in
                ListeningTrackStat(
                    track: ListeningTrackIdentity(
                        artistName: "Artist \(index)",
                        title: "Title \(index)",
                        albumTitle: "Album \(index)"
                    ),
                    plays: 10 - index
                )
            },
            topArtists: (1 ... 7).map { ListeningNameStat(name: "Artist \($0)", plays: 10 - $0) },
            topGenres: (1 ... 7).map { ListeningNameStat(name: "Genre \($0)", plays: 10 - $0) },
            hourHistogram: hours
        )
    }

    @Test("The projection cuts each ranked list to the top limit, in order")
    func projectionIsCutToBudget() {
        let context = InsightNarrationContext.projecting(Self.digest())
        #expect(context.topArtists.count == InsightNarrationContext.defaultTopLimit)
        #expect(context.topGenres.count == InsightNarrationContext.defaultTopLimit)
        #expect(context.topTracks.count == InsightNarrationContext.defaultTopLimit)
        #expect(context.topArtists.first == AssistantNameCount(name: "Artist 1", count: 9))
        #expect(context.topTracks.first?.title == "Title 1")
        #expect(context.window == .last30Days)
        #expect(context.totalPlays == 40)
    }

    @Test("The peak local hour breaks ties toward the earlier hour")
    func peakHourBreaksTiesEarly() {
        #expect(InsightNarrationContext.projecting(Self.digest()).peakLocalHour == 9)
    }

    @Test("A window with no raw events reports no peak hour")
    func emptyHistogramHasNoPeak() {
        let empty = ListeningWindowDigest(window: .allTime, hourHistogram: Array(repeating: 0, count: 24))
        #expect(InsightNarrationContext.projecting(empty).peakLocalHour == nil)
    }
}

@Suite("AssistantFakeBackends")
struct AssistantFakeBackendTests {
    @Test("The query-parser fake returns its script and records the request")
    func queryParserRecords() async throws {
        let scripted = PlaylistQuerySpec(genres: ["Rock"], targetCount: 12)
        let parser = FakeAssistantQueryParser(spec: scripted)
        let parsed = try await parser.parse(text: "upbeat 90s rock", locale: Locale(identifier: "en_US"))
        #expect(parsed == scripted)
        #expect(parser.recording.requests.count == 1)
        #expect(parser.recording.requests.first?.text == "upbeat 90s rock")
    }

    @Test("An armed failure throws the injected error, still recording the call")
    func queryParserFails() async {
        let parser = FakeAssistantQueryParser()
        parser.setFailure()
        await #expect(throws: FakeAssistantError.forcedFailure) {
            try await parser.parse(text: "anything", locale: .current)
        }
        #expect(parser.recording.requests.count == 1)
    }

    @Test("The naming fake returns its script and records the context")
    func namerRecords() async throws {
        let namer = FakeAssistantNamer(result: PlaylistNamingResult(name: "Rainy Sunday"))
        let context = PlaylistNamingContext(
            trackCount: 25,
            topGenres: [AssistantNameCount(name: "Rock", count: 15)],
            distinctArtistCount: 18,
            dominantDecade: 1990
        )
        let named = try await namer.suggestName(for: context, locale: Locale(identifier: "de_DE"))
        #expect(named.name == "Rainy Sunday")
        #expect(namer.recording.requests.first?.context == context)
        #expect(namer.recording.requests.first?.locale == Locale(identifier: "de_DE"))
    }

    @Test("The narration fake returns its script and records the context")
    func narratorRecords() async throws {
        let narrator = FakeAssistantNarrator()
        let context = InsightNarrationContext(window: .last7Days, totalPlays: 3)
        let narrated = try await narrator.narrate(context, locale: .current)
        #expect(narrated.narrative == "Fake narrative.")
        #expect(narrator.recording.requests.first?.context == context)
    }
}
