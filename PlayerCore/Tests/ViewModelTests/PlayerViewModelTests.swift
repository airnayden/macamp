import Artwork
import Foundation
import Services
import Testing
@testable import ViewModels

@MainActor
struct PlayerViewModelTests {
    private func makeRefs() -> [TrackRef] {
        [
            TrackRef(filePath: "/music/one.flac", title: "One", artist: "Artist", duration: 100),
            TrackRef(filePath: "/music/two.flac", title: "Two", artist: "Artist", duration: 120),
        ]
    }

    @Test func reflectsCoordinatorTransportState() {
        let coordinator = PlaybackCoordinator.fake()
        let model = PlayerViewModel(coordinator: coordinator, artworkProvider: FakeArtworkProvider())
        let refs = makeRefs()
        coordinator.setQueue(refs, startingAt: 0)

        #expect(model.currentTrack?.id == refs[0].id)
        #expect(model.isPlaying)
        #expect(model.duration > 0)

        model.pause()
        #expect(!model.isPlaying)

        model.next()
        #expect(model.currentTrack?.id == refs[1].id)
    }

    @Test func shuffleAndRepeatReflectCoordinator() {
        let coordinator = PlaybackCoordinator.fake()
        let model = PlayerViewModel(coordinator: coordinator, artworkProvider: FakeArtworkProvider())
        coordinator.setQueue(makeRefs(), startingAt: 0)
        model.setShuffle(true)
        #expect(model.shuffle)
        model.setRepeatMode(.all)
        #expect(model.repeatMode == .all)
    }

    @Test func resolvesArtworkOnTrackChange() async {
        let refs = makeRefs()
        let key = ArtworkRequest.AlbumKey(artist: "Artist", album: "")
        let result = ArtworkResult(data: Data([0x01, 0x02, 0x03]), contentHash: "abc", source: .cache)
        let provider = FakeArtworkProvider(responses: [key: result])
        let coordinator = PlaybackCoordinator.fake()
        let model = PlayerViewModel(coordinator: coordinator, artworkProvider: provider)
        coordinator.setQueue(refs, startingAt: 0)
        await pollUntil { model.artwork != nil }
        #expect(model.artwork?.contentHash == "abc")
        #expect(model.artwork?.source == .cache)
    }
}
