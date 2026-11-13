import Foundation
import MediaPlayer
@testable import Services
import Testing

struct NowPlayingServiceTests {
    private func makeService() -> (NowPlayingService, FakeNowPlayingInfoCenter) {
        let center = FakeNowPlayingInfoCenter()
        let service = NowPlayingService(infoCenter: center, snapshotWriter: FakeSnapshotWriter())
        return (service, center)
    }

    @Test("now-playing info reflects the current track")
    func trackMetadataReflected() throws {
        let (service, center) = makeService()
        service.updateTrack(NowPlayingMetadata(
            title: "Bohemian Rhapsody",
            artist: "Queen",
            album: "A Night at the Opera",
            duration: 354
        ))
        let info = try #require(center.nowPlayingInfo)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Bohemian Rhapsody")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Queen")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "A Night at the Opera")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 354)
    }

    @Test("play / pause / seek update elapsed and rate for system extrapolation")
    func transportUpdatesElapsedAndRate() throws {
        let (service, center) = makeService()
        service.updateTrack(NowPlayingMetadata(title: "Song", duration: 100))

        service.updatePlayback(.playing(elapsed: 5))
        var info = try #require(center.nowPlayingInfo)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 5)

        service.updatePlayback(.paused(elapsed: 42))
        info = try #require(center.nowPlayingInfo)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42)

        service.syncPosition(elapsed: 70)
        info = try #require(center.nowPlayingInfo)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 70)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    }

    @Test("advancing to the next track replaces the presented metadata")
    func nextTrackReplacesMetadata() throws {
        let (service, center) = makeService()
        service.updateTrack(NowPlayingMetadata(title: "First", duration: 10))
        service.updatePlayback(.playing(elapsed: 1))
        service.updateTrack(NowPlayingMetadata(title: "Second", artist: "B", duration: 20))
        let info = try #require(center.nowPlayingInfo)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Second")
        #expect(info[MPMediaItemPropertyArtist] as? String == "B")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 20)
    }

    @Test("artwork is published only when the provider yields one")
    func artworkFromProvider() throws {
        let center = FakeNowPlayingInfoCenter()
        let marker = NSObject()
        let service = NowPlayingService(
            infoCenter: center,
            snapshotWriter: nil,
            artworkProvider: { $0.artworkData == nil ? nil : marker }
        )
        service.updateTrack(NowPlayingMetadata(title: "Art", duration: 1, artworkData: Data([0x01])))
        let withArt = try #require(center.nowPlayingInfo)
        #expect(withArt[MPMediaItemPropertyArtwork] != nil)

        service.updateTrack(NowPlayingMetadata(title: "NoArt", duration: 1))
        let withoutArt = try #require(center.nowPlayingInfo)
        #expect(withoutArt[MPMediaItemPropertyArtwork] == nil)
    }

    @Test("clear tears down the now-playing info")
    func clearRemovesInfo() {
        let (service, center) = makeService()
        service.updateTrack(NowPlayingMetadata(title: "X", duration: 1))
        #expect(center.nowPlayingInfo != nil)
        service.clear()
        #expect(center.nowPlayingInfo == nil)
    }

    @Test("metadata maps from a queued TrackRef")
    func metadataFromTrackRef() {
        let track = TrackRef(filePath: "/music/song.flac", title: "Mapped", artist: "Mapper", duration: 123)
        let metadata = NowPlayingMetadata(track: track)
        #expect(metadata.title == "Mapped")
        #expect(metadata.artist == "Mapper")
        #expect(metadata.duration == 123)
    }

    @Test("a NowPlayingControlling fake records the pushed control surface")
    func controllerProtocolFake() {
        let fake = FakeNowPlayingController()
        let controller: NowPlayingControlling = fake
        controller.updateTrack(NowPlayingMetadata(title: "T", duration: 1))
        controller.updatePlayback(.playing(elapsed: 2))
        controller.syncPosition(elapsed: 3)
        controller.clear()
        #expect(fake.tracks.count == 1)
        #expect(fake.statuses == [.playing(elapsed: 2)])
        #expect(fake.positions == [3])
        #expect(fake.clearCount == 1)
    }
}
