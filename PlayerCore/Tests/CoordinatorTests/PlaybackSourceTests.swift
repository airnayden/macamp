import Foundation
import Services
import Testing

struct PlaybackSourceTests {
    @Test func everyCaseRoundTripsWithStableTaggedJSON() throws {
        let fixtures: [(source: PlaybackSource, json: String)] = [
            (.librarySection("allTracks"), #"{"kind":"librarySection","section":"allTracks"}"#),
            (.folder(path: "Music/Artist"), #"{"kind":"folder","path":"Music\/Artist"}"#),
            (.playlist(id: 42), #"{"kind":"playlist","playlistId":42}"#),
            (.favourites, #"{"kind":"favourites"}"#),
            (.karaokeReady, #"{"kind":"karaokeReady"}"#),
            (.search, #"{"kind":"search"}"#),
            (.albumDetail(id: 84), #"{"albumId":84,"kind":"albumDetail"}"#),
            (.artistDetail(id: 126), #"{"artistId":126,"kind":"artistDetail"}"#),
            (.stats, #"{"kind":"stats"}"#),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for fixture in fixtures {
            let encoded = try encoder.encode(fixture.source)
            let encodedString = try #require(String(data: encoded, encoding: .utf8))
            #expect(encodedString == fixture.json)
            let decoded = try JSONDecoder().decode(PlaybackSource.self, from: encoded)
            #expect(decoded == fixture.source)
        }
    }

    @Test func unknownFutureKindFailsLoudly() {
        let payload = Data(#"{"kind":"futureSource","futureId":7}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PlaybackSource.self, from: payload)
        }
    }

    @MainActor
    @Test func sourcePublishesBeforeReplacementQueueState() {
        let coordinator = PlaybackCoordinator(engine: SpyPlaybackEngine())
        var currentSource: PlaybackSource?
        var sourceSeenAtStateChange: PlaybackSource?
        coordinator.playbackSourceDidChange = { currentSource = $0 }
        coordinator.stateDidChange = { _ in sourceSeenAtStateChange = currentSource }

        coordinator.setQueue([.fixture("source")], startingAt: 0, source: .search)

        #expect(currentSource == .search)
        #expect(sourceSeenAtStateChange == .search)
    }
}
