import Foundation
import Models
@testable import Services
import Testing

struct NowPlayingSnapshotTests {
    @Test("snapshot round-trips through JSON")
    func snapshotCodableRoundTrip() throws {
        let snapshot = NowPlayingSnapshot(
            title: "Song",
            artist: "Artist",
            album: "Album",
            artworkRef: "art:1",
            duration: 180,
            elapsed: 30,
            isPlaying: true
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    @Test("snapshot payload is tiny — text only, no DB handle or blob")
    func snapshotPayloadIsSmall() throws {
        let snapshot = NowPlayingSnapshot(
            title: "A reasonably long song title",
            artist: "An Artist Name",
            album: "An Album Title",
            artworkRef: "art:cache-key-1234567890",
            duration: 240,
            elapsed: 99,
            isPlaying: true
        )
        let data = try JSONEncoder().encode(snapshot)
        #expect(data.count < 512)
    }

    @Test("the service writes a snapshot through the injected writer, never the DB")
    func writerReceivesSnapshot() throws {
        let writer = FakeSnapshotWriter()
        let service = NowPlayingService(infoCenter: FakeNowPlayingInfoCenter(), snapshotWriter: writer)
        service.updateTrack(NowPlayingMetadata(title: "Widget", duration: 10, artworkRef: "ref"))
        service.updatePlayback(.playing(elapsed: 3))
        #expect(writer.written.count == 2)
        let latest = try #require(writer.latest)
        #expect(latest.title == "Widget")
        #expect(latest.artworkRef == "ref")
        #expect(latest.isPlaying)
        #expect(latest.elapsed == 3)
    }

    @Test("clear writes a cleared snapshot")
    func clearWritesEmptySnapshot() throws {
        let writer = FakeSnapshotWriter()
        let service = NowPlayingService(infoCenter: FakeNowPlayingInfoCenter(), snapshotWriter: writer)
        service.updateTrack(NowPlayingMetadata(title: "X", duration: 1))
        service.clear()
        let latest = try #require(writer.latest)
        #expect(latest.title == "")
        #expect(latest.isPlaying == false)
    }

    @Test("UserDefaults writer persists JSON to an injected suite")
    func userDefaultsWriterPersists() throws {
        let suite = "test.macamp.nowplaying.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let writer = UserDefaultsSnapshotWriter(suiteName: suite, key: "snap")
        let snapshot = NowPlayingSnapshot(title: "Persisted", duration: 5, elapsed: 1, isPlaying: true)
        try writer.write(snapshot)
        let data = try #require(defaults.data(forKey: "snap"))
        let decoded = try JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }
}
