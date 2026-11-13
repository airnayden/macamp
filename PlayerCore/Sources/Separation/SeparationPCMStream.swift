import AVFAudio
import Decoding
import Foundation

/// Task-confined converter with bounded source pulls and one output window of
/// lookahead. Keeping the final window permits exact-duration trimming at EOF,
/// including sources whose declared length is unknown.
final class SeparationPCMStream {
    private let converter: AVAudioConverter
    private let input: SeparationPCMInput
    private let format: AVAudioFormat
    private let windowSize: AVAudioFrameCount
    private var pending: AVAudioPCMBuffer?
    private var converterEnded = false
    private var convertedFrames: Int64 = 0
    private(set) var emittedFrames: Int64 = 0
    let estimatedOutputFrames: Double?

    init(decoder: any PCMDecoding, blockSize: AVAudioFrameCount, windowSize: Int) throws {
        let source = decoder.processingFormat
        guard source.sampleRate.isFinite, source.sampleRate > 0 else { throw SeparationError.decodeFailed }
        guard (1 ... 2).contains(source.channelCount) else { throw SeparationError.unsupportedChannelLayout }
        guard windowSize > 0, windowSize <= Int(UInt32.max),
              let format = InstrumentalWriter.processingFormat,
              let converter = AVAudioConverter(from: source, to: format)
        else {
            throw SeparationError.decodeFailed
        }
        self.format = format
        self.converter = converter
        self.windowSize = AVAudioFrameCount(windowSize)
        input = try SeparationPCMInput(decoder: decoder, blockSize: max(blockSize, 1))
        estimatedOutputFrames = decoder.frameLength > 0
            ? Double(decoder.frameLength) * format.sampleRate / source.sampleRate : nil
        if source.channelCount == 1 { converter.channelMap = [0, 0] }
    }

    func next() throws -> AVAudioPCMBuffer? {
        try Task.checkCancellation()
        if pending == nil { pending = try convertWindow() }
        guard let current = pending else { return nil }
        pending = try convertWindow()
        if input.ended {
            let target = Int64((Double(input.frames) * format.sampleRate / input.sampleRate).rounded())
            let remaining = max(0, target - emittedFrames)
            current.frameLength = AVAudioFrameCount(min(Int64(current.frameLength), remaining))
            if pending == nil, converterEnded, remaining > Int64(current.frameLength) {
                let missing = remaining - Int64(current.frameLength)
                guard missing == 1 else { throw SeparationError.decodeFailed }
                try appendFinalFrame(to: current)
            }
        }
        guard current.frameLength > 0 else { return nil }
        emittedFrames += Int64(current.frameLength)
        return current
    }

    private func convertWindow() throws -> AVAudioPCMBuffer? {
        guard !converterEnded else { return nil }
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowSize) else {
            throw SeparationError.decodeFailed
        }
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { [input] requested, status in
            input.next(requested: requested, status: status)
        }
        if let failure = input.failure { throw failure }
        try Task.checkCancellation()
        guard error == nil, result != .error else { throw SeparationError.decodeFailed }
        converterEnded = result == .endOfStream
        convertedFrames += Int64(output.frameLength)
        if converterEnded {
            let expected = Int64((Double(input.frames) * format.sampleRate / input.sampleRate).rounded())
            guard input.ended, abs(convertedFrames - expected) <= 1 else { throw SeparationError.decodeFailed }
        }
        guard output.frameLength > 0 else {
            guard converterEnded else { throw SeparationError.decodeFailed }
            return nil
        }
        return output
    }

    /// Converter rate rounding can omit one terminal frame. Extend the final
    /// sample, never an entire missing window, to preserve rounded duration.
    private func appendFinalFrame(to current: AVAudioPCMBuffer) throws {
        guard current.frameLength > 0, let channels = current.floatChannelData else {
            throw SeparationError.decodeFailed
        }
        let last = Int(current.frameLength) - 1
        if current.frameLength < current.frameCapacity {
            channels[0][last + 1] = channels[0][last]
            channels[1][last + 1] = channels[1][last]
            current.frameLength += 1
        } else {
            guard let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1),
                  let destination = tail.floatChannelData else { throw SeparationError.decodeFailed }
            destination[0][0] = channels[0][last]
            destination[1][0] = channels[1][last]
            tail.frameLength = 1
            pending = tail
        }
    }
}

/// AVAudioConverter invokes its input callback synchronously. The decoder and
/// scratch buffer remain confined to that conversion call despite @Sendable.
private final class SeparationPCMInput: @unchecked Sendable {
    private let decoder: any PCMDecoding
    private let scratch: AVAudioPCMBuffer
    let sampleRate: Double
    private(set) var frames: Int64 = 0
    private(set) var ended = false
    private(set) var failure: (any Error)?

    init(decoder: any PCMDecoding, blockSize: AVAudioFrameCount) throws {
        self.decoder = decoder
        sampleRate = decoder.processingFormat.sampleRate
        guard let scratch = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: blockSize) else {
            throw SeparationError.decodeFailed
        }
        self.scratch = scratch
    }

    func next(
        requested: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        guard !ended, failure == nil else { status.pointee = .endOfStream; return nil }
        do {
            try Task.checkCancellation()
            let count = min(max(requested, 1), scratch.frameCapacity)
            let produced = try decoder.decode(into: scratch, frameLength: count)
            guard produced <= count, scratch.frameLength == produced else { throw SeparationError.decodeFailed }
            frames += Int64(produced)
            if produced == 0 {
                ended = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return scratch
        } catch {
            failure = error is CancellationError ? CancellationError() : SeparationError.decodeFailed
            status.pointee = .endOfStream
            return nil
        }
    }
}
