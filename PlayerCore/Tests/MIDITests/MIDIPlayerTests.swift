import AVFAudio
@testable import MIDI
import Testing

private let offlineMode = MIDIPlayer.RenderMode.offline(sampleRate: 44100, maximumFrameCount: 4096)

private func midiFixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func tinySoundFontURL() -> URL {
    midiFixtureURL("tiny.sf2")
}

private func scaleMIDIURL() -> URL {
    midiFixtureURL("scale.mid")
}

private func audioRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData else { return 0 }
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    guard frames > 0, channels > 0 else { return 0 }
    var sumOfSquares: Float = 0
    for channel in 0 ..< channels {
        let samples = data[channel]
        for frame in 0 ..< frames {
            sumOfSquares += samples[frame] * samples[frame]
        }
    }
    return (sumOfSquares / Float(frames * channels)).squareRoot()
}

@Suite(.serialized)
@MainActor
struct MIDIPlayerTests {
    @Test func directNoteRendersNonSilentThroughGraph() throws {
        let player = try MIDIPlayer(soundFont: tinySoundFontURL(), renderMode: offlineMode)
        try player.start()
        player.startNote(69)
        let buffer = try player.renderOffline(seconds: 1.0)
        #expect(audioRMS(buffer) > 0.01)
    }

    @Test func midiFileRendersNonSilent() throws {
        let player = try MIDIPlayer(soundFont: tinySoundFontURL(), renderMode: offlineMode)
        try player.load(url: scaleMIDIURL())
        try player.play()
        let buffer = try player.renderOffline(seconds: 2.0)
        #expect(audioRMS(buffer) > 0.01)
    }

    @Test func tapFeedsSpectrumFromGraphOutput() throws {
        let player = try MIDIPlayer(soundFont: tinySoundFontURL(), renderMode: offlineMode)
        try player.start()
        player.startNote(69)
        _ = try player.renderOffline(seconds: 0.5)
        let spectrum = player.latestSpectrum()
        #expect((spectrum.max() ?? 0) > 0.01)
    }

    @Test func eqGlobalGainAttenuatesGraphOutput() throws {
        let flat = try MIDIPlayer(soundFont: tinySoundFontURL(), renderMode: offlineMode)
        try flat.start()
        flat.startNote(69)
        let flatRMS = try audioRMS(flat.renderOffline(seconds: 0.5))

        let cut = try MIDIPlayer(soundFont: tinySoundFontURL(), renderMode: offlineMode)
        cut.setGlobalGain(-96)
        try cut.start()
        cut.startNote(69)
        let cutRMS = try audioRMS(cut.renderOffline(seconds: 0.5))

        #expect(flatRMS > 0.01)
        #expect(cutRMS < flatRMS * 0.1)
    }

    @Test func graphAttachesEQ() throws {
        let player = try MIDIPlayer(soundFont: tinySoundFontURL(), renderMode: offlineMode)
        #expect(player.isEQInstalled)
    }

    @Test func loadSetsLoadedStateAndDuration() throws {
        let player = try MIDIPlayer(soundFont: tinySoundFontURL(), renderMode: offlineMode)
        #expect(player.isLoaded == false)
        try player.load(url: scaleMIDIURL())
        #expect(player.isLoaded)
        #expect(abs(player.duration - 4.0) < 0.2)
    }

    @Test func playPauseResumeAdvancesPlayhead() throws {
        let player = try MIDIPlayer(soundFont: tinySoundFontURL(), renderMode: offlineMode)
        try player.load(url: scaleMIDIURL())
        try player.play()
        #expect(player.isPlaying)
        _ = try player.renderOffline(seconds: 0.5)
        let afterFirstRender = player.currentTime
        #expect(afterFirstRender > 0.3)

        player.pause()
        #expect(player.isPlaying == false)
        #expect(abs(player.currentTime - afterFirstRender) < 0.05)

        try player.play()
        _ = try player.renderOffline(seconds: 0.5)
        #expect(player.currentTime > afterFirstRender + 0.2)
    }

    @Test func seekClampsToDuration() throws {
        let player = try MIDIPlayer(soundFont: tinySoundFontURL(), renderMode: offlineMode)
        try player.load(url: scaleMIDIURL())
        player.seek(to: 2.0)
        #expect(abs(player.currentTime - 2.0) < 0.001)
        player.seek(to: 999)
        #expect(abs(player.currentTime - player.duration) < 0.001)
        player.seek(to: -10)
        #expect(player.currentTime == 0)
    }

    @Test func stopResetsPlayhead() throws {
        let player = try MIDIPlayer(soundFont: tinySoundFontURL(), renderMode: offlineMode)
        try player.load(url: scaleMIDIURL())
        try player.play()
        _ = try player.renderOffline(seconds: 0.5)
        player.stop()
        #expect(player.isPlaying == false)
        #expect(player.currentTime == 0)
    }

    @Test func invalidSoundFontThrows() {
        let bogus = URL(fileURLWithPath: "/nonexistent/macamp-bogus.sf2")
        #expect(throws: MIDIPlayerError.self) {
            _ = try MIDIPlayer(soundFont: bogus, renderMode: offlineMode)
        }
    }

    @Test func invalidMIDIFileThrows() throws {
        let player = try MIDIPlayer(soundFont: tinySoundFontURL(), renderMode: offlineMode)
        let bogus = URL(fileURLWithPath: "/nonexistent/macamp-bogus.mid")
        #expect(throws: MIDIPlayerError.self) {
            try player.load(url: bogus)
        }
    }
}
