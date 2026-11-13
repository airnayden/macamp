// CrossfeedRenderState — the pre-allocated input-pull storage and the in-place
// mix step ``CrossfeedAudioUnit``'s render block runs on the audio thread.
//
// Split out of `CrossfeedAudioUnit.swift` so the render-thread code — the part
// bound by the zero-allocation / zero-lock / zero-log invariant — reads as one
// self-contained unit, separate from the unit's construction and bus plumbing.
//
// EVERYTHING HERE RUNS ON THE RENDER THREAD except ``allocate(format:maximumFrames:)``
// and ``deallocate()``, which run inside `allocateRenderResources()` /
// `deallocateRenderResources()`. Nothing in the render path allocates, locks,
// logs, or retains: the buffer is allocated once when the graph is prepared, and
// the pull list's pointers are merely restored in place on every block.
//
// This file imports only AVFAudio + AudioToolbox + DSP + Darwin; it MUST NOT
// import AppKit or UIKit (PlayerCore portability invariant).
import AudioToolbox
import AVFAudio
import Darwin
import DSP

/// The pull buffer ``CrossfeedAudioUnit`` hands upstream, allocated once when the
/// graph is prepared.
///
/// `@unchecked Sendable` is sound because the only mutation after
/// ``allocate(format:maximumFrames:)`` happens on the render thread, and the
/// render block is the single consumer: `AUAudioUnit` guarantees render resources
/// are allocated before rendering starts and deallocated after it stops.
final class CrossfeedRenderState: @unchecked Sendable {
    /// Owns the backing storage the pull list's `mData` pointers refer to.
    private var buffer: AVAudioPCMBuffer?

    /// The buffer's pristine list — the `mData` pointers and channel counts as
    /// `AVAudioPCMBuffer` laid them out. Read-only; ``prepare(frameCount:)``
    /// copies from it.
    private var pristineList: UnsafePointer<AudioBufferList>?

    /// The list handed to `pullInputBlock`. An upstream node may overwrite its
    /// `mData` pointers with its own storage (the null-buffer optimisation), so
    /// it is restored from ``pristineList`` before every pull.
    private(set) var pullList: UnsafeMutablePointer<AudioBufferList>?

    private var maximumFrames: AUAudioFrameCount = 0

    /// Allocates the pull buffer for `format` at `maximumFrames`. Returns `false`
    /// when the buffer could not be created, which the caller turns into a
    /// refused `allocateRenderResources()`.
    func allocate(format: AVAudioFormat, maximumFrames: AUAudioFrameCount) -> Bool {
        guard maximumFrames > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames)
        else {
            return false
        }
        buffer = pcmBuffer
        pristineList = UnsafePointer(pcmBuffer.audioBufferList)
        pullList = pcmBuffer.mutableAudioBufferList
        self.maximumFrames = maximumFrames
        return true
    }

    /// Releases the pull buffer. Runs in `deallocateRenderResources()`, never
    /// while rendering.
    func deallocate() {
        buffer = nil
        pristineList = nil
        pullList = nil
        maximumFrames = 0
    }

    /// Render-thread path. Restores the pull list's buffer pointers, channel
    /// counts and byte sizes so the upstream node writes into OUR storage.
    ///
    /// This is not housekeeping: `pullInputBlock` is allowed to replace `mData`
    /// with a pointer to the upstream node's own buffer, and a stale
    /// `mDataByteSize` from a previous, longer block would let it write past the
    /// frames this one asked for.
    func prepare(frameCount: AUAudioFrameCount) {
        guard let pristineList, let pullList else { return }
        let frames = min(frameCount, maximumFrames)
        let byteSize = UInt32(frames) * UInt32(MemoryLayout<Float>.size)
        pullList.pointee.mNumberBuffers = pristineList.pointee.mNumberBuffers
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: pristineList))
        let destination = UnsafeMutableAudioBufferListPointer(pullList)
        for index in 0 ..< source.count {
            destination[index].mNumberChannels = source[index].mNumberChannels
            destination[index].mData = source[index].mData
            destination[index].mDataByteSize = byteSize
        }
    }
}

/// The render-thread mix step: move the pulled input into the output list, then
/// crossfeed it in place.
///
/// A caseless enum rather than a method so the render block never has to capture
/// `self` — it captures the kernel and the state, both pre-allocated.
enum CrossfeedRenderMix {
    /// Copies `input` into `output` (or adopts the input storage when the host
    /// asked for in-place processing) and runs `kernel` over the first two
    /// de-interleaved channels.
    ///
    /// Zero heap allocation, zero locks, zero ARC traffic, zero logging.
    ///
    /// A layout the kernel cannot serve — mono, an interleaved stereo pair
    /// (`mNumberBuffers == 1`, two channels), or a bus with fewer than two
    /// buffers — passes through UNCHANGED rather than being mangled: crossfeed is
    /// a stereo-image tool and has no meaning outside a de-interleaved L/R pair.
    static func process(
        kernel: CrossfeedKernel,
        input: UnsafeMutablePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AUAudioFrameCount
    ) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(input)
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
        let byteSize = Int(frameCount) * MemoryLayout<Float>.size
        let bufferCount = min(inputBuffers.count, outputBuffers.count)

        for index in 0 ..< bufferCount {
            // A null `mData` is the host saying "process in place" — point the
            // output at the storage we just pulled into.
            if outputBuffers[index].mData == nil {
                outputBuffers[index].mData = inputBuffers[index].mData
            }
            outputBuffers[index].mDataByteSize = UInt32(byteSize)
            if outputBuffers[index].mData != inputBuffers[index].mData {
                memcpy(outputBuffers[index].mData, inputBuffers[index].mData, byteSize)
            }
        }

        guard bufferCount >= 2,
              outputBuffers[0].mNumberChannels == 1,
              outputBuffers[1].mNumberChannels == 1,
              let left = outputBuffers[0].mData,
              let right = outputBuffers[1].mData
        else {
            return
        }
        kernel.process(
            left: left.assumingMemoryBound(to: Float.self),
            right: right.assumingMemoryBound(to: Float.self),
            frameCount: Int(frameCount)
        )
    }
}
