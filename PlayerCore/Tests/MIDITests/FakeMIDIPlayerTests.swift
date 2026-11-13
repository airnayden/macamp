import Foundation
@testable import MIDI
import Testing

@MainActor
struct FakeMIDIPlayerTests {
    private func sampleURL() -> URL {
        URL(fileURLWithPath: "/tmp/song.mid")
    }

    @Test func loadEstablishesLoadedStateAndDuration() throws {
        let player = FakeMIDIPlayer()
        #expect(player.isLoaded == false)
        try player.load(url: sampleURL())
        #expect(player.isLoaded)
        #expect(player.duration == 10)
        #expect(player.loadedURL?.lastPathComponent == "song.mid")
    }

    @Test func playPauseStopTransitions() throws {
        let player = FakeMIDIPlayer()
        try player.load(url: sampleURL())
        try player.play()
        #expect(player.isPlaying)
        player.pause()
        #expect(player.isPlaying == false)
        try player.play()
        player.stop()
        #expect(player.isPlaying == false)
        #expect(player.currentTime == 0)
    }

    @Test func playBeforeLoadIsNoOp() throws {
        let player = FakeMIDIPlayer()
        try player.play()
        #expect(player.isPlaying == false)
    }

    @Test func seekClampsToDuration() throws {
        let player = FakeMIDIPlayer()
        try player.load(url: sampleURL())
        player.seek(to: 5)
        #expect(player.currentTime == 5)
        player.seek(to: 999)
        #expect(player.currentTime == 10)
        player.seek(to: -3)
        #expect(player.currentTime == 0)
    }

    @Test func loadErrorPropagates() {
        let player = FakeMIDIPlayer()
        player.loadError = MIDIPlayerError.notOfflineMode
        #expect(throws: MIDIPlayerError.self) {
            try player.load(url: sampleURL())
        }
    }
}
