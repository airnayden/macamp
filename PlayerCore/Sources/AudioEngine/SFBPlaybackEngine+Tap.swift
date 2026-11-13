// SFBPlaybackEngine+Tap — the POST-EQ metering tap and its render-thread body.
//
// Split out of `SFBPlaybackEngine.swift` for the reason its siblings were
// (`+OutputRouting`, `+Parametric`, `+Crossfeed`): that file sits at SwiftLint's
// 400-line ceiling, so appending to it is no longer free. Keeping the tap apart
// also isolates the one piece of this engine that executes on a real-time
// thread — everything in this file is bound by the audio-thread invariant, and
// nothing else in the engine is.
//
// This file imports only AVFAudio + DSP; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import AVFAudio
import DSP

extension SFBPlaybackEngine {
    /// Frames requested per tap callback — the visualizer's DELIVERY latency.
    ///
    /// Core Audio fills a whole tap buffer before invoking the closure, so this
    /// value is the floor on how long a transient waits before it even reaches
    /// the ring: 4096 frames ≈ 93 ms at 44.1 kHz, 1024 ≈ 23 ms. The ring
    /// (16384) and the analyzer's 4096-sample FFT read are deliberately
    /// UNCHANGED — a smaller request only makes the history the analyzer peeks
    /// fresher. The 4× callback rate costs nothing: the tap body is two memcpys.
    nonisolated static let tapBufferSize: AVAudioFrameCount = 1024

    /// Installs the POST-EQ tap on `node`, replacing any existing tap.
    ///
    /// The tap host is the EQ OUTPUT — deliberately PRE-pan and PRE-crossfeed.
    /// Channel 0 feeds the visualizer, so a post-pan tap would collapse it to
    /// silence at full-right balance; taking the signal ahead of both stages also
    /// keeps the meter reading the programme rather than the headphone
    /// processing applied to it.
    ///
    /// The tap closure is `@Sendable` (non-isolated) so AVFAudio may invoke it on
    /// the render thread without tripping Swift 6's actor-isolation assertion. It
    /// captures only the `Sendable` provider and forwards to the alloc-free static
    /// ``ingest(_:into:)``.
    nonisolated static func installTap(on node: AVAudioNode, into provider: SpectrumProvider) {
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: tapBufferSize, format: nil) { @Sendable buffer, _ in
            ingest(buffer, into: provider)
        }
    }

    /// AUDIO-THREAD INVARIANT: read the metered channels and one memcpy each into
    /// their own lock-free ring. No allocation, no locks, no logging. The DSP
    /// layer is PULL-based, so the tap never pushes downstream.
    ///
    /// Channel 1 is copied ONLY when the buffer actually carries it.
    /// ``SFBPlaybackEngine/connectionFormat(for:)`` passes the SOURCE format
    /// through, so a mono file yields a one-channel tap buffer and
    /// `floatChannelData?[1]` would be an out-of-bounds read ON THE RENDER
    /// THREAD. For a mono source the channel-1 ring is simply left unwritten,
    /// retaining whatever the previous stereo source put there.
    ///
    /// Nothing about that decision is published from here — that would reopen the
    /// render-thread shared-state surface the zero-allocation invariant closes.
    /// The consumer re-reads the count itself from
    /// ``PlaybackEngine/currentConnectionFormat``, which is the SAME
    /// `AVAudioFormat.channelCount` this guard reads, so the two can never
    /// disagree about whether channel 1 is real.
    nonisolated static func ingest(_ buffer: AVAudioPCMBuffer, into provider: SpectrumProvider) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        provider.ingest(channels[0], count: frameCount)
        guard buffer.format.channelCount >= 2 else { return }
        provider.ingestChannel1(channels[1], count: frameCount)
    }
}
