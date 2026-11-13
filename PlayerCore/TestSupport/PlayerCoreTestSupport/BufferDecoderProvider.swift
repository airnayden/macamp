// BufferDecoderProvider — vends an already-synthesised sample array as a decoder.
//
// `FakeDecoderProvider` covers the closed-form-sine case, but analysis tests need
// arbitrary waveforms — a click train, a chirp, a pre-recorded envelope. This
// provider takes whatever `[Float]` a generator produced and serves it through
// the ordinary ``PCMDecoding`` pull interface, so the code under test sees a
// perfectly normal decoder and never learns the samples were synthetic.
//
// It also counts `decode` calls (thread-safely, since consumers decode off the
// caller's thread), which is what lets a cancellation test prove a pass stopped
// PART-WAY through a file rather than merely refusing to start.
//
// This file imports only AVFAudio + Decoding + Foundation; it MUST NOT import
// AppKit or UIKit (PlayerCore portability invariant).
import AVFAudio
import Decoding
import Foundation

/// A ``DecoderProviding`` backend that replays a fixed mono sample array.
public struct BufferDecoderProvider: DecoderProviding {
    /// The mono samples every vended decoder replays, in order.
    public let samples: [Float]
    /// The sample rate the decoders advertise.
    public let sampleRate: Double

    private let counter = DecodeCallCounter()

    public init(samples: [Float], sampleRate: Double = 44100) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public func makeDecoder(for _: URL) throws -> any PCMDecoding {
        BufferPCMDecoder(samples: samples, sampleRate: sampleRate, counter: counter)
    }

    /// How many `decode(into:frameLength:)` calls every decoder this provider
    /// vended has served so far.
    public var decodeCallCount: Int {
        counter.value
    }

    /// How many `decode` calls a full pass takes at `frameLength` frames each —
    /// the ceiling a cancelled pass must stay below.
    public func expectedDecodeCallCount(frameLength: Int) -> Int {
        guard frameLength > 0 else { return 0 }
        return (samples.count + frameLength - 1) / frameLength
    }

    public static let supportedPathExtensions: Set<String> = ["wav", "aiff", "flac", "mp3", "caf", "fake"]
    public static let supportedMIMETypes: Set<String> = ["audio/wav", "audio/aiff", "audio/flac", "audio/mpeg"]
}

/// A ``PCMDecoding`` that reads sequentially out of a fixed sample array.
final class BufferPCMDecoder: PCMDecoding {
    let processingFormat: AVAudioFormat
    let sourceFormat: AVAudioFormat? = nil
    let frameLength: AVAudioFramePosition
    private(set) var framePosition: AVAudioFramePosition = 0
    let supportsSeeking = true

    private let samples: [Float]
    private let counter: DecodeCallCounter

    init(samples: [Float], sampleRate: Double, counter: DecodeCallCounter) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            fatalError("standard mono float format unconstructible at \(sampleRate) Hz")
        }
        processingFormat = format
        frameLength = AVAudioFramePosition(samples.count)
        self.samples = samples
        self.counter = counter
    }

    @discardableResult
    func decode(into buffer: AVAudioPCMBuffer, frameLength frames: AVAudioFrameCount) throws -> AVAudioFrameCount {
        counter.increment()
        let remaining = frameLength - framePosition
        guard remaining > 0, let data = buffer.floatChannelData else {
            buffer.frameLength = 0
            return 0
        }
        let toProduce = min(Int(frames), Int(buffer.frameCapacity), Int(remaining))
        let start = Int(framePosition)
        for frame in 0 ..< toProduce {
            data[0][frame] = samples[start + frame]
        }
        buffer.frameLength = AVAudioFrameCount(toProduce)
        framePosition += AVAudioFramePosition(toProduce)
        return AVAudioFrameCount(toProduce)
    }

    @discardableResult
    func seek(toFrame frame: AVAudioFramePosition) throws -> AVAudioFramePosition {
        framePosition = max(0, min(frame, frameLength))
        return framePosition
    }
}

/// Shared decode-call tally. A reference type so every decoder a (value-type)
/// provider vends reports into the same counter, lock-guarded because the pass
/// under test decodes on its own detached thread.
final class DecodeCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
