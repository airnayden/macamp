@testable import AudioEngine
import AVFAudio
import Foundation
import Testing

/// Real-engine coverage of the decoder-OBJECT hand-off. Handing a decoder to the
/// live `SFBAudioPlayer` needs a default output device, so — exactly like
/// ``SFBReloadTests`` — these are gated behind `MACAMP_AUDIO_HW=1` (CI has no
/// device; ``DecoderSourceLoadTests`` covers the contract hermetically there).
/// Run locally:
///   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MACAMP_AUDIO_HW=1 \
///     swift test --filter SFBDecoderObjectLoadTests
///
/// Every test plays before asserting `duration`: `SFBAudioPlayer.totalTime`
/// reports the CURRENT decoder, which an enqueue alone has not yet made current —
/// asserting it while merely `.stopped` is a race (measured). This is the same
/// play-then-assert shape ``SFBReloadTests`` uses, for the same reason.
@MainActor
@Suite(.serialized)
struct SFBDecoderObjectLoadTests {
    @Test(
        "load(source:) hands a real FLAC decoder to the player, which then renders it",
        .enabled(if: ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1")
    )
    func loadSourceHandsDecoderToPlayer() throws {
        let engine = SFBPlaybackEngine()

        try engine.load(source: DecoderSource(url: AudioEngineFixtures.flac))
        #expect(engine.state == .stopped)
        engine.play()

        #expect(engine.state == .playing)
        #expect(engine.duration > 0)
        #expect(engine.isEQInstalled)
        engine.stop()
    }

    @Test(
        "a frame-ranged source reaches the player as a region decoder",
        .enabled(if: ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1")
    )
    func rangedSourceReachesThePlayer() throws {
        let whole = SFBPlaybackEngine()
        try whole.load(source: DecoderSource(url: AudioEngineFixtures.flac))
        whole.play()
        let wholeDuration = whole.duration
        whole.stop()
        #expect(wholeDuration > 0)

        let region = SFBPlaybackEngine()
        try region.load(source: DecoderSource(url: AudioEngineFixtures.flac, frameRange: 0 ..< 4410))
        region.play()

        #expect(region.duration > 0)
        #expect(region.duration < wholeDuration, "the region decoder never reached the player")
        region.stop()
    }

    @Test(
        "a corrupt source throws and the engine still loads a good URL afterwards",
        .enabled(if: ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1")
    )
    func corruptSourceLeavesEngineUsable() throws {
        let engine = SFBPlaybackEngine()

        #expect(throws: DecodingError.self) {
            try engine.load(source: DecoderSource(url: AudioEngineFixtures.corruptFlac))
        }

        try engine.load(AudioEngineFixtures.flac)
        engine.play()
        #expect(engine.state == .playing)
        #expect(engine.duration > 0)
        engine.stop()
    }
}
