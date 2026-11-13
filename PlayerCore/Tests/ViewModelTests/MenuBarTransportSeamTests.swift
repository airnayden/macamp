// MenuBarTransportSeamTests — pins the exact call path the menu-bar mini
// player's previous / next buttons use.
//
// `MenuBarView`'s transport passes `environment.player.previous` and
// `environment.player.next` as button actions, so the seam under test is
// ``PlayerViewModel/next()`` / ``PlayerViewModel/previous()`` forwarding to the
// coordinator — not the coordinator's own navigation, which
// `PlaybackCoordinatorTests` already covers.
import Artwork
import Foundation
import Services
import Testing
@testable import ViewModels

@MainActor
struct MenuBarTransportSeamTests {
    private func makeSeam() -> (PlayerViewModel, [TrackRef]) {
        let refs = [
            TrackRef(filePath: "/music/one.flac", title: "One", artist: "Artist", duration: 100),
            TrackRef(filePath: "/music/two.flac", title: "Two", artist: "Artist", duration: 120),
            TrackRef(filePath: "/music/three.flac", title: "Three", artist: "Artist", duration: 140),
        ]
        let coordinator = PlaybackCoordinator.fake()
        let model = PlayerViewModel(coordinator: coordinator, artworkProvider: FakeArtworkProvider())
        coordinator.setQueue(refs, startingAt: 0)
        return (model, refs)
    }

    @Test("next() advances through a three-track queue")
    func nextAdvances() {
        let (model, refs) = makeSeam()
        #expect(model.currentTrack?.id == refs[0].id)
        model.next()
        #expect(model.currentTrack?.id == refs[1].id)
        model.next()
        #expect(model.currentTrack?.id == refs[2].id)
    }

    @Test("previous() retreats through a three-track queue")
    func previousRetreats() {
        let (model, refs) = makeSeam()
        model.next()
        model.next()
        #expect(model.currentTrack?.id == refs[2].id)
        model.previous()
        #expect(model.currentTrack?.id == refs[1].id)
        model.previous()
        #expect(model.currentTrack?.id == refs[0].id)
    }

    @Test("previous() at the head of the queue is a no-op")
    func previousAtHeadHolds() {
        let (model, refs) = makeSeam()
        model.previous()
        #expect(model.currentTrack?.id == refs[0].id)
    }
}
