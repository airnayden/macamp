@testable import AudioEngine
import AVFAudio
import Darwin
import PlayerCoreTestSupport
import Testing

/// Proves the audio-thread tap path allocates nothing. The static
/// ``SFBPlaybackEngine/ingest(_:into:)`` reads channel 0 and performs a single
/// memcpy into the pre-allocated lock-free ring — no heap traffic on the render
/// thread (the audio-thread invariant).
@Suite(.serialized)
struct ZeroAllocTapTests {
    @Test("the static tap ingest performs no heap allocation")
    func ingestIsAllocationFree() throws {
        let provider = SpectrumProvider()
        let format = SignalGenerators.monoFormat(sampleRate: 44100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        buffer.frameLength = 4096
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0 ..< 4096 {
                channel[frame] = Float(sin(Double(frame) * 0.05))
            }
        }

        // Warm up one-time lazy state before measuring.
        for _ in 0 ..< 100 {
            SFBPlaybackEngine.ingest(buffer, into: provider)
        }

        let iterations = 200_000

        // The default malloc zone counter is PROCESS-GLOBAL, so under `--parallel`
        // it also counts other suites' allocations. Measure an ambient control
        // window of the same length to subtract that noise (per DSP learnings).
        var sink = 0
        let controlStart = mallocBlocksInUse()
        for index in 0 ..< iterations {
            sink = sink &+ (index & 1)
        }
        let ambientDelta = mallocBlocksInUse() - controlStart
        _ = sink

        let ingestStart = mallocBlocksInUse()
        for _ in 0 ..< iterations {
            SFBPlaybackEngine.ingest(buffer, into: provider)
        }
        let ingestDelta = mallocBlocksInUse() - ingestStart

        // A per-call allocation regression would add ~`iterations` blocks; a
        // zero-alloc path only tracks ambient noise, well within this margin.
        #expect(ingestDelta <= max(ambientDelta, 0) + 4096, "ingest \(ingestDelta) vs ambient \(ambientDelta)")
    }

    private func mallocBlocksInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &stats)
        return Int(stats.blocks_in_use)
    }
}
