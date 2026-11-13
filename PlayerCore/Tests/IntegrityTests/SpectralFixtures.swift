import AVFAudio
import Foundation

/// Locates the committed spectral-detector fixtures next to this test target.
///
/// `Fixtures/` is excluded from the build (see Package.swift) and loaded by path
/// via `#filePath`, mirroring the Metadata / Decoding / ParametricEQ pattern. See
/// `Fixtures/README.md` for provenance — including why these two are committed
/// while todo 26's FLAC MD5 fixtures are encoded in-test.
enum SpectralFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    /// A FLAC laundered from a 128 kbps MP3 of the wideband source — content stops
    /// at the encoder's ~16 kHz lowpass.
    static var transcoded: URL {
        directory.appendingPathComponent("wideband-transcoded-128k.flac")
    }

    /// The same wideband source encoded straight to FLAC — flat to Nyquist. The
    /// false-positive guard.
    static var lossless: URL {
        directory.appendingPathComponent("wideband-lossless.flac")
    }
}

/// Writes throwaway audio into a temp directory so the failure paths can be driven
/// through the real decoder without committing a fixture for each of them.
struct TemporaryAudioFile {
    let url: URL
    private let directory: URL

    init(name: String) {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macamp-spectral-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent(name)
    }

    func writeSilence(sampleRate: Double, seconds: Double) throws {
        try write(sampleRate: sampleRate, seconds: seconds) { _, _ in 0 }
    }

    func write(
        sampleRate: Double,
        seconds: Double,
        sample: (Int, Double) -> Float
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleRate * seconds)
            ),
            let channel = buffer.floatChannelData
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        let frames = Int(buffer.frameCapacity)
        for frame in 0 ..< frames {
            channel[0][frame] = sample(frame, sampleRate)
        }
        buffer.frameLength = AVAudioFrameCount(frames)

        let file = try AVAudioFile(forWriting: url, settings: Self.pcm16Settings(sampleRate: sampleRate))
        try file.write(from: buffer)
    }

    /// Interleaved 16-bit PCM on disk — the one WAV shape every decoder opens
    /// without argument. `AVAudioFile` converts from the float buffer on write.
    private static func pcm16Settings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
