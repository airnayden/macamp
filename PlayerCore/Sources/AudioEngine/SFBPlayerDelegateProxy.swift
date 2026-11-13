// SFBPlayerDelegateProxy — the off-main relay between `SFBPlaybackEngine` and
// SFB's `AudioPlayer` delegate callbacks.
//
// Split out of `SFBPlaybackEngine.swift` (which is at its file-length budget).
// These three types form one unit: the boxes carry values written on the main
// actor across to SFB's unspecified notification thread, where the proxy reads
// the gain box and ``ProcessingNodeChain`` reads the balance box. Graph re-wiring
// on format change is delegated to that chain, so the reconfigure path and the
// engine's first build traverse ONE description — see `reconfigureProcessingGraph`.
//
// This file imports only AVFAudio + DSP + Foundation + SFBAudioEngine; it MUST
// NOT import AppKit or UIKit (PlayerCore portability invariant).
import AVFAudio
import DSP
import Foundation
@preconcurrency import SFBAudioEngine

// MARK: - Global-gain box

/// A tiny lock-protected box for the ReplayGain global gain (dB).
///
/// Written on the main actor (``SFBPlaybackEngine/setGlobalGain(_:)``) and read on
/// SFB's unspecified notification thread (`renderingWillStart`), so access is
/// guarded by an `NSLock`. `@unchecked Sendable` is sound because every access
/// goes through the lock.
final class GlobalGainBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Float = 0

    var value: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedValue = newValue
        }
    }
}

/// The same lock-protected relay for balance, read by `reconfigureProcessingGraph`
/// so a graph rebuild can restore the user's pan on the new connection.
final class BalanceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Float = 0

    var value: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedValue = newValue
        }
    }
}

// MARK: - Delegate proxy

/// Off-main delegate for `AudioPlayer`. Both callbacks run in SFB's graph-safe
/// context (an unspecified queue), so this is `@unchecked Sendable` and only
/// touches the processing chain and the gain box it was handed.
final class PlayerDelegateProxy: NSObject, AudioPlayer.Delegate, @unchecked Sendable {
    private let chain: ProcessingNodeChain
    private let globalGainBox: GlobalGainBox
    var onRenderingCompleteCallback: (@Sendable () -> Void)?
    var onRenderingWillCompleteCallback: (@Sendable () -> Void)?

    init(chain: ProcessingNodeChain, globalGainBox: GlobalGainBox) {
        self.chain = chain
        self.globalGainBox = globalGainBox
        super.init()
    }

    /// Re-establishes the whole processing chain on every format change, always
    /// with the PASSED format (the nodes' own formats are stale here), then
    /// re-applies balance and the pre-pan tap. SFB still connects its source to
    /// the returned node, so the chain head remains the graph's entry point.
    ///
    /// The traversal lives in ``ProcessingNodeChain/wire(into:from:terminatingAt:format:)``
    /// so this path and the engine's first build can never describe a different
    /// chain. `from: nil` because SFB owns the upstream connection here.
    func audioPlayer(
        _ audioPlayer: AudioPlayer,
        reconfigureProcessingGraph engine: AVAudioEngine,
        with format: AVAudioFormat
    ) -> AVAudioNode {
        chain.wire(into: engine, from: nil, terminatingAt: audioPlayer.mainMixerNode, format: format)
    }

    func audioPlayer(
        _: AudioPlayer,
        renderingWillStart _: any SFBAudioEngine.PCMDecoding,
        at _: UInt64
    ) {
        chain.equalizer.globalGain = globalGainBox.value
    }

    func audioPlayer(
        _: AudioPlayer,
        renderingComplete _: any SFBAudioEngine.PCMDecoding
    ) {
        onRenderingCompleteCallback?()
    }

    func audioPlayer(
        _: AudioPlayer,
        renderingWillComplete _: any SFBAudioEngine.PCMDecoding,
        at _: UInt64
    ) {
        onRenderingWillCompleteCallback?()
    }
}
