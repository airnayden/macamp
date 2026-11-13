// OfflineRenderHarness — the hardware-free testability unlock for MacAMP.
//
// Drives an `AVAudioEngine` in `.offline` manual rendering mode so that audio
// graphs can be rendered deterministically into an `AVAudioPCMBuffer` with no
// real audio hardware, no run loop, and no wall-clock timing. Every engine TDD
// suite in this project builds on top of this harness.
//
// This file imports only `AVFAudio` + `Foundation`; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import AVFAudio
import Foundation

/// Errors thrown by the offline render harness.
public enum OfflineRenderError: Error, CustomStringConvertible {
    case engineStartFailed(String)
    case renderFailed(String)
    case bufferAllocationFailed
    case fileReadFailed(String)

    public var description: String {
        switch self {
        case let .engineStartFailed(reason): "engine start failed: \(reason)"
        case let .renderFailed(reason): "offline render failed: \(reason)"
        case .bufferAllocationFailed: "failed to allocate an AVAudioPCMBuffer"
        case let .fileReadFailed(reason): "file read failed: \(reason)"
        }
    }
}

/// A deterministic, hardware-free renderer for `AVAudioEngine` graphs.
///
/// The harness never touches real audio hardware: it relies exclusively on
/// `enableManualRenderingMode(.offline:format:maximumFrameCount:)` followed by a
/// synchronous `renderOffline(_:to:)` loop. There is no use of
/// `DispatchQueue.main.async` — rendering is fully synchronous.
public enum OfflineRenderHarness {
    /// The default per-render-block frame count used by the harness.
    public static let defaultMaximumFrameCount: AVAudioFrameCount = 4096

    /// Renders an arbitrary engine graph offline and returns the collected samples.
    ///
    /// - Parameters:
    ///   - format: The processing/output format (e.g. mono float @ 44.1 kHz).
    ///   - duration: How many seconds of audio to render.
    ///   - maximumFrameCount: Per-render-block size (default 4096).
    ///   - buildGraph: A closure that receives the `AVAudioEngine`, **attaches**
    ///     any nodes it creates, wires them together, and returns the *terminal*
    ///     node, which the harness connects to `outputNode` using `format`.
    ///     NOTE: connect to `outputNode`, never `mainMixerNode` — the latter applies
    ///     a -3 dB equal-power pan law to mono inputs that breaks level assertions.
    /// - Returns: A single `AVAudioPCMBuffer` containing all rendered frames.
    /// - Throws: ``OfflineRenderError`` on engine start / render / allocation failure.
    public static func render(
        format: AVAudioFormat,
        duration: Double,
        maximumFrameCount: AVAudioFrameCount = defaultMaximumFrameCount,
        buildGraph: (AVAudioEngine) -> AVAudioNode
    ) throws -> AVAudioPCMBuffer {
        let engine = AVAudioEngine()
        let terminal = buildGraph(engine)
        engine.connect(terminal, to: engine.outputNode, format: format)

        let totalFrames = AVAudioFrameCount((duration * format.sampleRate).rounded())
        return try drive(
            engine: engine,
            totalFrames: totalFrames,
            maximumFrameCount: maximumFrameCount,
            format: format
        )
    }

    /// Renders an on-disk audio file offline through an `AVAudioPlayerNode` and
    /// returns the rendered samples. Used by `macamp-cli render`/`analyze`.
    ///
    /// The file is fully read into memory first and scheduled as an in-memory
    /// buffer so that offline rendering never stalls on disk I/O.
    public static func renderFile(
        url: URL,
        maximumFrameCount: AVAudioFrameCount = defaultMaximumFrameCount
    ) throws -> AVAudioPCMBuffer {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw OfflineRenderError.fileReadFailed(error.localizedDescription)
        }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            throw OfflineRenderError.bufferAllocationFailed
        }
        do {
            try file.read(into: inputBuffer)
        } catch {
            throw OfflineRenderError.fileReadFailed(error.localizedDescription)
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.outputNode, format: format)

        try configureOfflineEngine(engine, format: format, maximumFrameCount: maximumFrameCount)
        player.scheduleBuffer(inputBuffer, at: nil, options: [], completionHandler: nil)
        player.play()

        return try renderLoop(
            engine: engine,
            totalFrames: frameCount,
            maximumFrameCount: maximumFrameCount
        )
    }

    // MARK: - Private

    /// Enables offline rendering, starts the engine, and runs the render loop.
    private static func drive(
        engine: AVAudioEngine,
        totalFrames: AVAudioFrameCount,
        maximumFrameCount: AVAudioFrameCount,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        try configureOfflineEngine(engine, format: format, maximumFrameCount: maximumFrameCount)
        return try renderLoop(
            engine: engine,
            totalFrames: totalFrames,
            maximumFrameCount: maximumFrameCount
        )
    }

    /// Puts the engine into offline manual-rendering mode and starts it.
    private static func configureOfflineEngine(
        _ engine: AVAudioEngine,
        format: AVAudioFormat,
        maximumFrameCount: AVAudioFrameCount
    ) throws {
        do {
            try engine.enableManualRenderingMode(
                .offline,
                format: format,
                maximumFrameCount: maximumFrameCount
            )
        } catch {
            throw OfflineRenderError.engineStartFailed(
                "enableManualRenderingMode: \(error.localizedDescription)"
            )
        }
        do {
            try engine.start()
        } catch {
            throw OfflineRenderError.engineStartFailed(error.localizedDescription)
        }
    }

    /// Synchronously pulls `totalFrames` frames out of the engine and collects
    /// them into one big buffer. Stops the engine before returning.
    private static func renderLoop(
        engine: AVAudioEngine,
        totalFrames: AVAudioFrameCount,
        maximumFrameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        defer { engine.stop() }

        let renderFormat = engine.manualRenderingFormat
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: renderFormat,
                frameCapacity: max(totalFrames, 1)
            ),
            let scratch = AVAudioPCMBuffer(
                pcmFormat: renderFormat,
                frameCapacity: maximumFrameCount
            )
        else {
            throw OfflineRenderError.bufferAllocationFailed
        }

        var framesRemaining = totalFrames
        while framesRemaining > 0 {
            let framesToRender = min(scratch.frameCapacity, framesRemaining)
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(framesToRender, to: scratch)
            } catch {
                throw OfflineRenderError.renderFailed(error.localizedDescription)
            }

            switch status {
            case .success, .insufficientDataFromInputNode:
                // `.insufficientDataFromInputNode` still produces (silent-padded)
                // frames; treat it as a normal render so finite graphs terminate.
                guard scratch.frameLength > 0 else {
                    framesRemaining = 0
                    continue
                }
                append(scratch, to: output)
                framesRemaining -= min(scratch.frameLength, framesRemaining)
            case .cannotDoInCurrentContext:
                // Transient: retry the same block.
                continue
            case .error:
                throw OfflineRenderError.renderFailed("renderOffline returned .error")
            @unknown default:
                throw OfflineRenderError.renderFailed("unknown manual rendering status")
            }
        }
        return output
    }

    /// Appends every channel of `src` onto the end of `dst` (non-interleaved float).
    private static func append(_ src: AVAudioPCMBuffer, to dst: AVAudioPCMBuffer) {
        guard
            let srcData = src.floatChannelData,
            let dstData = dst.floatChannelData
        else { return }

        let srcFrames = Int(src.frameLength)
        let dstOffset = Int(dst.frameLength)
        let capacityLeft = Int(dst.frameCapacity) - dstOffset
        let copyCount = min(srcFrames, capacityLeft)
        guard copyCount > 0 else { return }

        let channels = Int(src.format.channelCount)
        for channel in 0 ..< channels {
            let source = srcData[channel]
            let destination = dstData[channel].advanced(by: dstOffset)
            destination.update(from: source, count: copyCount)
        }
        dst.frameLength += AVAudioFrameCount(copyCount)
    }
}
