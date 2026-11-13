import AVFAudio
import Foundation
import os
@preconcurrency import SFBAudioEngine

/// Phase 0 spike — **Option A** audio engine controller.
///
/// SFBAudioEngine 0.12.1 ships NO public `SFBAudioPlayerNode`, so Option B (two player
/// nodes → mixer for native crossfade) is not buildable on the pinned version. This
/// uses Option A: the high-level `AudioPlayer` (`SFBAudioPlayer`) owns the
/// `AVAudioEngine`; we insert a 10-band `AVAudioUnitEQ` between its source node and the
/// main mixer via `modifyProcessingGraph` (+ the `reconfigureProcessingGraph` delegate
/// for format changes) and tap the main mixer (post-EQ) into a lock-free SPSC ring
/// buffer that feeds the vDSP FFT + Metal spectrum.
@MainActor
final class SpikeController: ObservableObject {
    /// Shared with the Metal view. Multiple readers each copy the latest window
    /// independently; the single producer is the audio tap.
    let ringBuffer = SPSCRingBuffer()

    private let player = AudioPlayer()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private lazy var delegateProxy = PlayerDelegateProxy(eq: eq, ringBuffer: ringBuffer)

    // Diagnostic FFT on the display thread — proves tap-fired + non-zero FFT in the
    // logs independent of the GPU path (the iOS evidence relies on this).
    private let fft = SpectrumFFT()
    private var diagScratch = [Float](repeating: 0, count: SpectrumFFT.fftSize)
    private var diagTask: Task<Void, Never>?
    private var didAutoStart = false
    private let snapshotRenderer = SpectrumSnapshotRenderer()

    private let logger = Logger(subsystem: "com.example.macamp.spike", category: "audio")

    @Published var status = "idle"
    @Published var samplesWritten: UInt64 = 0
    @Published var fftPeak: Float = 0
    @Published var windowRMS: Float = 0
    @Published var eqEngaged = false

    init() {
        setvbuf(stdout, nil, _IONBF, 0)
        #if os(iOS)
        configureAudioSession()
        #endif
        configureEQBands()
        player.delegate = delegateProxy
        insertEQAndTap()
        startDiagnostics()
        log("init — Option A graph: source → 10-band EQ → mainMixer(tap) → output")
    }

    deinit {
        diagTask?.cancel()
    }

    // MARK: - Setup

    #if os(iOS)
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            log("AVAudioSession .playback active")
        } catch {
            log("AVAudioSession error: \(error.localizedDescription)")
        }
    }
    #endif

    private func configureEQBands() {
        // The 10-band layout from the MacAMP audio research (L4).
        let specs: [(AVAudioUnitEQFilterType, Float)] = [
            (.lowShelf, 80), (.parametric, 250), (.parametric, 500), (.parametric, 1_000),
            (.parametric, 2_000), (.parametric, 4_000), (.parametric, 8_000), (.parametric, 12_000),
            (.parametric, 16_000), (.highShelf, 20_000),
        ]
        for (index, spec) in specs.enumerated() {
            let band = eq.bands[index]
            band.filterType = spec.0
            band.frequency = spec.1
            band.bandwidth = 0.5
            band.gain = 0
            band.bypass = false
        }
        // ReplayGain would be applied here (invariant across Option A and B).
        eq.globalGain = 0
    }

    /// Insert the EQ between source and main mixer and install the post-EQ tap once.
    /// The proxy's `reconfigureProcessingGraph` re-establishes both on format changes.
    private func insertEQAndTap() {
        let eq = self.eq
        let player = self.player
        let ringBuffer = self.ringBuffer
        player.modifyProcessingGraph { engine in
            if eq.engine == nil { engine.attach(eq) }
            let sourceFormat = player.sourceNode.outputFormat(forBus: 0)
            let format = sourceFormat.channelCount > 0
                ? sourceFormat
                : AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            engine.disconnectNodeOutput(player.sourceNode)
            engine.connect(player.sourceNode, to: eq, format: format)
            engine.connect(eq, to: player.mainMixerNode, format: format)

            // POST-EQ tap → ring buffer. AUDIO-THREAD INVARIANT: read the provided
            // buffer + one memcpy + one atomic store. No alloc/lock/ARC/log here.
            player.mainMixerNode.removeTap(onBus: 0)
            player.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { @Sendable buffer, _ in
                guard let channel0 = buffer.floatChannelData?[0] else { return }
                ringBuffer.write(channel0, count: Int(buffer.frameLength))
            }
        }
    }

    // MARK: - Transport

    func playFLAC() { play(resource: "sweep", ext: "flac") }
    func playMP3() { play(resource: "sweep", ext: "mp3") }

    /// Gapless: enqueue the next decoder; SFB pre-rolls it (same SR/channels = no gap).
    func enqueueMP3Gapless() {
        guard let url = Bundle.main.url(forResource: "sweep", withExtension: "mp3") else {
            log("enqueue: missing sweep.mp3")
            return
        }
        do {
            try player.enqueue(url)
            log("enqueued sweep.mp3 for gapless playback (queueIsEmpty=\(player.queueIsEmpty))")
        } catch {
            log("enqueue error: \(error.localizedDescription)")
        }
    }

    private func play(resource: String, ext: String) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else {
            status = "missing \(resource).\(ext)"
            log("MISSING bundled resource \(resource).\(ext)")
            return
        }
        do {
            try player.play(url)
            status = "playing \(resource).\(ext)"
            log("play \(resource).\(ext) (engineRunning=\(player.engineIsRunning))")
        } catch {
            status = "play error"
            log("play error for \(resource).\(ext): \(error.localizedDescription)")
        }
    }

    // MARK: - EQ verification

    /// Toggle a deep cut on the mid parametric bands (250 Hz … 4 kHz) where the FLAC
    /// chirp lives, so the tapped RMS visibly drops — proving the EQ is in the path.
    func toggleEQ() {
        eqEngaged.toggle()
        let gain: Float = eqEngaged ? -24 : 0
        for index in 1...5 { eq.bands[index].gain = gain }
        log("EQ \(eqEngaged ? "ENGAGED: 250 Hz–4 kHz at -24 dB" : "FLAT (0 dB)")")
    }

    // MARK: - Autostart (drives screenshots / headless logs without UI interaction)

    func autoStart() {
        guard !didAutoStart else { return }
        didAutoStart = true
        playFLAC()
        enqueueMP3Gapless()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.log("=== EQ A/B: engaging mid cut to verify EQ affects the signal ===")
            self?.toggleEQ()
        }
        #if os(macOS)
        if let directory = ProcessInfo.processInfo.environment["SPIKE_SNAPSHOT_DIR"] {
            scheduleHeadlessSnapshots(into: URL(fileURLWithPath: directory, isDirectory: true))
        }
        #endif
    }

    #if os(macOS)
    private func scheduleHeadlessSnapshots(into directory: URL) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            self?.captureSnapshot(named: "task-7-spike-macos-frame1.png", in: directory)
            try? await Task.sleep(for: .milliseconds(1200))
            self?.captureSnapshot(named: "task-7-spike-macos-frame2.png", in: directory)
            try? await Task.sleep(for: .seconds(2))
            self?.log("headless snapshot run complete; exiting")
            exit(0)
        }
    }
    #endif

    private func captureSnapshot(named name: String, in directory: URL) {
        ringBuffer.readLatest(into: &diagScratch, count: SpectrumFFT.fftSize)
        let bands = fft.process(diagScratch)
        let url = directory.appendingPathComponent(name)
        let ok = snapshotRenderer?.renderPNG(bands: bands, width: 900, height: 320, to: url) ?? false
        log(String(format: "snapshot %@ ok=%@ peak=%.3f", name, ok ? "YES" : "no", bands.max() ?? 0))
    }

    // MARK: - Diagnostics

    private func startDiagnostics() {
        diagTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    private func tick() {
        let written = ringBuffer.samplesWritten
        ringBuffer.readLatest(into: &diagScratch, count: SpectrumFFT.fftSize)
        let bands = fft.process(diagScratch)
        let peak = bands.max() ?? 0
        var sumSquares: Float = 0
        for index in 0..<SpectrumFFT.fftSize {
            let value = diagScratch[index]
            sumSquares += value * value
        }
        let rms = sqrtf(sumSquares / Float(SpectrumFFT.fftSize))
        samplesWritten = written
        fftPeak = peak
        windowRMS = rms
        log(String(format: "tap samples=%llu fftPeak=%.3f rms=%.4f eq=%@ nonZero=%@",
                   written, peak, rms,
                   eqEngaged ? "cut" : "flat",
                   peak > 0.001 ? "YES" : "no"))
    }

    private func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        print("[SPIKE] \(message)")
    }
}

/// Off-main delegate for `AudioPlayer`. The `reconfigureProcessingGraph` callback runs
/// in SFB's graph-safe context (unspecified queue), so this is `@unchecked Sendable` and
/// only touches the engine + EQ + ring buffer it was handed.
final class PlayerDelegateProxy: NSObject, AudioPlayer.Delegate, @unchecked Sendable {
    private let eq: AVAudioUnitEQ
    private let ringBuffer: SPSCRingBuffer

    init(eq: AVAudioUnitEQ, ringBuffer: SPSCRingBuffer) {
        self.eq = eq
        self.ringBuffer = ringBuffer
        super.init()
    }

    func audioPlayer(_ audioPlayer: AudioPlayer,
                     reconfigureProcessingGraph engine: AVAudioEngine,
                     with format: AVAudioFormat) -> AVAudioNode {
        if eq.engine == nil { engine.attach(eq) }
        engine.connect(eq, to: audioPlayer.mainMixerNode, format: format)

        // Re-establish the post-EQ tap after every reconfiguration.
        let ringBuffer = self.ringBuffer
        audioPlayer.mainMixerNode.removeTap(onBus: 0)
        audioPlayer.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { @Sendable buffer, _ in
            guard let channel0 = buffer.floatChannelData?[0] else { return }
            ringBuffer.write(channel0, count: Int(buffer.frameLength))
        }
        return eq
    }
}
