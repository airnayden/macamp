// MIDIPlayer — the production ``MIDIPlaying`` backed by `AVAudioUnitSampler`.
//
// MIDI playback reuses the AudioEngine "Option A" graph shape so EQ, the DSP
// visualizer, and now-playing metadata observe sampler output exactly like
// decoded-file output: sampler → AVAudioUnitEQ(10) → mainMixer (a POST-EQ tap
// feeds a DSP ``SpectrumProvider``) → output. ``AVAudioSequencer`` parses and
// sequences the `.mid`/`.midi` file; transport drives the sequencer while the
// player tracks the playhead itself, so pause/resume and seek are exact
// regardless of the sequencer's `stop()` position semantics.
//
// The SoundFont is loaded ONCE at init (off the audio render thread — the hot
// path never touches disk). PlayerCore's MIDI target declares no SPM resources,
// so the production `.sf2` is injected by the app shell; tests inject a tiny
// generated fixture. `.offline` render mode powers hermetic, hardware-free tests
// and an offline MIDI→audio bounce via ``renderOffline(seconds:)``.
//
// This file imports only AudioEngine + AudioToolbox + AVFAudio + Foundation; it
// MUST NOT import AppKit or UIKit (PlayerCore portability invariant). AudioEngine
// re-exports DSP, surfacing ``SpectrumProvider`` and the shared EQ helpers.
import AudioEngine
import AudioToolbox
import AVFAudio
import Foundation

/// A failure raised while configuring or driving a ``MIDIPlayer``.
public enum MIDIPlayerError: Error, CustomStringConvertible {
    case soundFontLoadFailed(url: URL, reason: String)
    case sequenceLoadFailed(url: URL, reason: String)
    case engineStartFailed(String)
    case notOfflineMode
    case renderFailed(String)

    public var description: String {
        switch self {
        case let .soundFontLoadFailed(url, reason):
            "sound font load failed (\(url.lastPathComponent)): \(reason)"
        case let .sequenceLoadFailed(url, reason):
            "MIDI sequence load failed (\(url.lastPathComponent)): \(reason)"
        case let .engineStartFailed(reason):
            "engine start failed: \(reason)"
        case .notOfflineMode:
            "renderOffline requires a player created with .offline render mode"
        case let .renderFailed(reason):
            "offline render failed: \(reason)"
        }
    }
}

/// Production ``MIDIPlaying``: an `AVAudioUnitSampler` loaded from a SoundFont and
/// driven by an `AVAudioSequencer`, routed through the shared EQ + tap graph.
@MainActor
public final class MIDIPlayer: MIDIPlaying {
    /// How the underlying `AVAudioEngine` renders.
    ///
    /// `.realtime` drives the output hardware; `.offline` enables manual
    /// rendering (hardware-free) so tests and an offline bounce can pull frames
    /// through ``renderOffline(seconds:)``.
    public enum RenderMode: Sendable, Equatable {
        case realtime
        case offline(sampleRate: Double, maximumFrameCount: AVAudioFrameCount)
    }

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private let equalizer = makeEQUnit()
    private let spectrumProvider = SpectrumProvider()
    private lazy var sequencer = AVAudioSequencer(audioEngine: engine)
    private let renderMode: RenderMode

    private var loaded = false
    private var playing = false
    private var pausedPlayhead: TimeInterval = 0
    private var cachedDuration: TimeInterval = 0

    /// Builds the graph and loads `soundFontURL` into the sampler.
    ///
    /// - Parameters:
    ///   - soundFontURL: A `.sf2`/`.dls` General-MIDI bank. The app shell bundles
    ///     the production bank; tests pass a tiny generated fixture.
    ///   - program: The melodic program (instrument) to select (default 0).
    ///   - renderMode: `.realtime` (default) or `.offline` for manual rendering.
    /// - Throws: ``MIDIPlayerError`` if the engine cannot enter manual rendering
    ///   mode or the SoundFont cannot be loaded.
    public init(
        soundFont soundFontURL: URL,
        program: UInt8 = 0,
        renderMode: RenderMode = .realtime
    ) throws {
        self.renderMode = renderMode

        engine.attach(sampler)
        engine.attach(equalizer)
        engine.connect(sampler, to: equalizer, format: nil)
        engine.connect(equalizer, to: engine.mainMixerNode, format: nil)
        Self.installTap(on: engine.mainMixerNode, into: spectrumProvider)

        if case let .offline(sampleRate, maximumFrameCount) = renderMode {
            let format = try Self.makeRenderFormat(sampleRate: sampleRate)
            do {
                try engine.enableManualRenderingMode(
                    .offline,
                    format: format,
                    maximumFrameCount: maximumFrameCount
                )
            } catch {
                throw MIDIPlayerError.engineStartFailed(
                    "enableManualRenderingMode: \(error.localizedDescription)"
                )
            }
            engine.reset()
        }

        do {
            try sampler.loadSoundBankInstrument(
                at: soundFontURL,
                program: program,
                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB)
            )
        } catch {
            throw MIDIPlayerError.soundFontLoadFailed(
                url: soundFontURL,
                reason: error.localizedDescription
            )
        }
    }
}

// MARK: - Transport

public extension MIDIPlayer {
    var isLoaded: Bool {
        loaded
    }

    var isPlaying: Bool {
        playing
    }

    var duration: TimeInterval {
        cachedDuration
    }

    var currentTime: TimeInterval {
        get { playing ? sequencer.currentPositionInSeconds : pausedPlayhead }
        set { seek(to: newValue) }
    }

    func load(url: URL) throws {
        if playing {
            sequencer.stop()
            playing = false
        }
        do {
            try sequencer.load(from: url, options: [])
        } catch {
            throw MIDIPlayerError.sequenceLoadFailed(url: url, reason: error.localizedDescription)
        }
        cachedDuration = sequencer.tracks.map(\.lengthInSeconds).max() ?? 0
        sequencer.currentPositionInSeconds = 0
        pausedPlayhead = 0
        loaded = true
    }

    func play() throws {
        try start()
        sequencer.currentPositionInSeconds = pausedPlayhead
        sequencer.prepareToPlay()
        do {
            try sequencer.start()
        } catch {
            throw MIDIPlayerError.engineStartFailed("sequencer.start: \(error.localizedDescription)")
        }
        playing = true
    }

    func pause() {
        guard playing else { return }
        pausedPlayhead = sequencer.currentPositionInSeconds
        sequencer.stop()
        playing = false
    }

    func stop() {
        sequencer.stop()
        sequencer.currentPositionInSeconds = 0
        pausedPlayhead = 0
        playing = false
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), max(0, cachedDuration))
        pausedPlayhead = clamped
        sequencer.currentPositionInSeconds = clamped
    }
}

// MARK: - Engine, EQ, spectrum, manual notes

public extension MIDIPlayer {
    /// Starts the engine if it is not already running (hardware for `.realtime`,
    /// a manual-rendering session for `.offline`). Idempotent.
    func start() throws {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            throw MIDIPlayerError.engineStartFailed(error.localizedDescription)
        }
    }

    /// Stops playback, removes the tap, and tears the engine down.
    func shutdown() {
        if playing {
            sequencer.stop()
            playing = false
        }
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Sets the gain (dB) of EQ band `index`; out-of-range indices are ignored.
    func setBandGain(_ index: Int, dB decibels: Float) {
        guard equalizer.bands.indices.contains(index) else { return }
        equalizer.bands[index].gain = decibels
    }

    /// Sets the EQ global trim (dB), clamped via ``clampGlobalGain(_:)``.
    func setGlobalGain(_ decibels: Float) {
        equalizer.globalGain = clampGlobalGain(decibels)
    }

    /// The latest 128-band spectrum, pulled on demand from the POST-EQ tap.
    func latestSpectrum() -> [Float] {
        spectrumProvider.latestSpectrum()
    }

    /// Triggers a note directly on the sampler (e.g. a MIDI keyboard UI), bypassing
    /// the sequence. Requires the engine to be running (call ``start()`` first).
    func startNote(_ note: UInt8, velocity: UInt8 = 100, channel: UInt8 = 0) {
        sampler.startNote(note, withVelocity: velocity, onChannel: channel)
    }

    /// Releases a note previously started with ``startNote(_:velocity:channel:)``.
    func stopNote(_ note: UInt8, channel: UInt8 = 0) {
        sampler.stopNote(note, onChannel: channel)
    }
}

// MARK: - Offline rendering

public extension MIDIPlayer {
    /// Renders the current state offline into a single PCM buffer (an offline
    /// MIDI→audio bounce; the hermetic test path). Requires `.offline` mode.
    ///
    /// The POST-EQ tap fires during manual rendering, so ``latestSpectrum()``
    /// reflects the rendered audio afterwards.
    /// - Throws: ``MIDIPlayerError/notOfflineMode`` when not in `.offline` mode,
    ///   or ``MIDIPlayerError/renderFailed(_:)`` on allocation/render failure.
    func renderOffline(seconds: TimeInterval) throws -> AVAudioPCMBuffer {
        guard case .offline = renderMode else { throw MIDIPlayerError.notOfflineMode }
        try start()

        let format = engine.manualRenderingFormat
        let totalFrames = AVAudioFrameCount(max(0, seconds) * format.sampleRate)
        guard
            totalFrames > 0,
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
            let scratch = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: engine.manualRenderingMaximumFrameCount
            )
        else {
            throw MIDIPlayerError.renderFailed("buffer allocation failed")
        }

        var framesRemaining = totalFrames
        while framesRemaining > 0 {
            let framesToRender = min(scratch.frameCapacity, framesRemaining)
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(framesToRender, to: scratch)
            } catch {
                throw MIDIPlayerError.renderFailed(error.localizedDescription)
            }
            switch status {
            case .success, .insufficientDataFromInputNode:
                guard scratch.frameLength > 0 else { framesRemaining = 0; continue }
                Self.append(scratch, to: output)
                framesRemaining -= min(scratch.frameLength, framesRemaining)
            case .cannotDoInCurrentContext:
                continue
            case .error:
                throw MIDIPlayerError.renderFailed("renderOffline returned .error")
            @unknown default:
                throw MIDIPlayerError.renderFailed("unknown manual rendering status")
            }
        }
        return output
    }
}

// MARK: - Graph helpers (non-isolated, audio-thread-safe)

extension MIDIPlayer {
    /// Installs the POST-EQ tap on `mixer`, replacing any existing tap. The
    /// closure is `@Sendable` so AVFAudio may invoke it on the render thread
    /// without tripping Swift 6's actor-isolation assertion.
    nonisolated static func installTap(on mixer: AVAudioMixerNode, into provider: SpectrumProvider) {
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 4096, format: nil) { @Sendable buffer, _ in
            ingest(buffer, into: provider)
        }
    }

    /// AUDIO-THREAD INVARIANT: read channel 0 and one memcpy into the lock-free
    /// ring — no allocation, no locks, no ARC, no logging. The DSP layer is
    /// PULL-based, so the tap never pushes downstream.
    nonisolated static func ingest(_ buffer: AVAudioPCMBuffer, into provider: SpectrumProvider) {
        guard let channel0 = buffer.floatChannelData?[0] else { return }
        provider.ingest(channel0, count: Int(buffer.frameLength))
    }

    /// Appends every channel of `source` onto the end of `destination`
    /// (non-interleaved float), bounded by the destination's remaining capacity.
    nonisolated static func append(_ source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) {
        guard
            let sourceData = source.floatChannelData,
            let destinationData = destination.floatChannelData
        else { return }
        let offset = Int(destination.frameLength)
        let capacityLeft = Int(destination.frameCapacity) - offset
        let copyCount = min(Int(source.frameLength), capacityLeft)
        guard copyCount > 0 else { return }
        let channels = Int(source.format.channelCount)
        for channel in 0 ..< channels {
            destinationData[channel].advanced(by: offset)
                .update(from: sourceData[channel], count: copyCount)
        }
        destination.frameLength += AVAudioFrameCount(copyCount)
    }

    static func makeRenderFormat(sampleRate: Double) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw MIDIPlayerError.renderFailed("unconstructible render format at \(sampleRate) Hz")
        }
        return format
    }
}

// MARK: - Test hooks

extension MIDIPlayer {
    var isEngineRunning: Bool {
        engine.isRunning
    }

    var isEQInstalled: Bool {
        equalizer.engine != nil
    }
}
