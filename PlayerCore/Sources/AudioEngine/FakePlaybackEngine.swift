// FakePlaybackEngine — the deterministic, file-free ``PlaybackEngine`` double.
//
// Split out of `PlaybackEngine.swift` verbatim: that file held the protocol, its
// neutral defaults, the standby format AND this double, and each seam added to
// the contract has to be mirrored here, so the two grew together past SwiftLint's
// 400-line ceiling. The split follows the module's existing one-type-per-file
// pattern (`SFBPlaybackEngine+OutputRouting.swift`, `ParametricEQNode.swift`) and
// leaves both halves room for the seams still to come.
//
// The double lives in the SHIPPING module rather than `PlayerCoreTestSupport`
// because `PlaybackEngine`'s own contract tests and the app shells' previews both
// reach for it, and `AudioEngine` cannot depend on its own test-support package.
//
// This file imports only AVFAudio + Decoding + DSP + Foundation + Models; it MUST
// NOT import AppKit or UIKit (PlayerCore portability invariant).
import AVFAudio
import Decoding
import DSP
import Foundation
import Models

/// A deterministic, file-free ``PlaybackEngine`` for tests.
///
/// Validates `load`/`enqueue` through an injected ``DecoderProviding`` (so a
/// corrupt source throws a typed ``DecodingError`` and the engine survives),
/// drives the transport state machine, and records band/global gains for
/// assertions. There is no `AVAudioEngine` and no audio thread — every
/// transition is synchronous on the main actor.
@MainActor
public final class FakePlaybackEngine: PlaybackEngine {
    public private(set) var state: PlaybackState = .idle {
        didSet { stateDidChange?(state) }
    }

    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public var stateDidChange: ((PlaybackState) -> Void)?

    /// Per-band gains (dB), indexed like ``EQBand`` `rawValue`s.
    public private(set) var bandGains: [Float]
    /// The most recent clamped value passed to ``setGlobalGain(_:)``.
    public private(set) var globalGain: Float = 0

    private let decoderProvider: any DecoderProviding

    public init(decoderProvider: any DecoderProviding = FakeDecoderProvider()) {
        self.decoderProvider = decoderProvider
        bandGains = [Float](repeating: 0, count: EQBand.allCases.count)
    }

    public func load(_ url: URL) throws {
        try load(source: DecoderSource(url: url))
    }

    public func enqueue(_ url: URL) throws {
        try enqueue(source: DecoderSource(url: url))
    }

    public func load(source: DecoderSource) throws {
        let decoder = try decoderProvider.makeDecoder(for: source)
        let frames = decoder.frameLength
        let rate = decoder.processingFormat.sampleRate
        duration = frames > 0 && rate > 0 ? Double(frames) / rate : 0
        currentTime = 0
        state = .stopped
    }

    public func enqueue(source: DecoderSource) throws {
        _ = try decoderProvider.makeDecoder(for: source)
    }

    public func play() {
        guard state != .idle else { return }
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        state = .paused
    }

    public func stop() {
        currentTime = 0
        state = .stopped
    }

    public func seek(to time: TimeInterval) {
        currentTime = min(max(time, 0), duration)
    }

    public func reload(url: URL, at time: TimeInterval, resumePlaying: Bool) throws {
        try reload(source: DecoderSource(url: url), at: time, resumePlaying: resumePlaying)
    }

    public func reload(source: DecoderSource, at time: TimeInterval, resumePlaying: Bool) throws {
        try load(source: source)
        seek(to: time)
        if resumePlaying {
            play()
        } else {
            state = .paused
        }
    }

    public func setBandGain(_ index: Int, dB decibels: Float) {
        guard bandGains.indices.contains(index) else { return }
        bandGains[index] = decibels
    }

    public func setGlobalGain(_ decibels: Float) {
        globalGain = clampGlobalGain(decibels)
    }

    // MARK: - Parametric EQ

    /// The configuration most recently ACCEPTED by
    /// ``setParametricConfiguration(_:)``, or `nil` when the stage is bypassed.
    ///
    /// A spy property rather than a protocol member: the production engine keeps
    /// no copy of the configuration (its node IS the state), and a getter derived
    /// from the node's parameters could not reproduce it — the Q → bandwidth
    /// conversion is clamped into the AU's legal range on the way in.
    public private(set) var parametricConfiguration: ParametricEQConfiguration?

    /// Every configuration passed to ``setParametricConfiguration(_:)``, in call
    /// order — INCLUDING the over-capacity ones that were refused.
    ///
    /// Refused requests are recorded for the same reason
    /// ``requestedOutputDeviceIDs`` records them: a caller that re-pushes a
    /// profile the engine cannot hold is a bug an assertion on the accepted
    /// configuration alone cannot see.
    public private(set) var requestedParametricConfigurations: [ParametricEQConfiguration?] = []

    public func setParametricConfiguration(_ configuration: ParametricEQConfiguration?) throws {
        requestedParametricConfigurations.append(configuration)
        try configuration?.validateFilterCapacity()
        parametricConfiguration = configuration
        gainComposer.setParametricPreamp(Float(configuration?.preampDB ?? 0))
    }

    public private(set) var volume: Float = 1.0
    public private(set) var balance: Float = 0
    public var onEndOfAudio: (() -> Void)?
    public var onRenderingComplete: (() -> Void)?

    public func setVolume(_ newVolume: Float) {
        volume = min(max(newVolume, 0), 1)
    }

    public func setBalance(_ newBalance: Float) {
        balance = min(max(newBalance, -1), 1)
    }

    // MARK: - Crossfeed

    public private(set) var crossfeedLevel: CrossfeedLevel?

    /// Every crossfeed request in call order — a disable records `nil`.
    ///
    /// The whole history rather than just the current state, for the same reason
    /// ``requestedOutputDeviceIDs`` keeps one: a caller that re-pushes the same
    /// level on every track change is a bug an assertion on ``crossfeedLevel``
    /// alone cannot see.
    public private(set) var requestedCrossfeedLevels: [CrossfeedLevel?] = []

    public func setCrossfeed(enabled: Bool, fcut: Double, feedDB: Double) {
        let level = enabled ? CrossfeedLevel(cutFrequency: fcut, feedDB: feedDB) : nil
        requestedCrossfeedLevels.append(level)
        crossfeedLevel = level
    }

    // MARK: - Output routing

    public private(set) var outputDeviceID: OutputDeviceID?

    /// Every identifier passed to ``setOutputDeviceID(_:)``, in call order —
    /// INCLUDING the ones ``outputDeviceSelectionError`` refused.
    ///
    /// Refused requests are recorded on purpose: a caller that retries a dead
    /// device on every track change is a bug an assertion on ``outputDeviceID``
    /// alone cannot see.
    public private(set) var requestedOutputDeviceIDs: [OutputDeviceID] = []

    /// When non-`nil`, ``setOutputDeviceID(_:)`` throws this instead of routing —
    /// the seam for driving the "persisted device is gone" path with no hardware.
    public var outputDeviceSelectionError: OutputDeviceSelectionError?

    /// The format this engine reports as its graph format.
    ///
    /// Settable so a test can present a mono or hi-res graph (a metering consumer
    /// mirrors channel 0 onto channel 1 when this reports fewer than 2 channels).
    public var currentConnectionFormat: AVAudioFormat = PlaybackEngineFormats.standby

    public func setOutputDeviceID(_ deviceID: OutputDeviceID) throws {
        requestedOutputDeviceIDs.append(deviceID)
        if let outputDeviceSelectionError {
            throw outputDeviceSelectionError
        }
        outputDeviceID = deviceID
    }
}
