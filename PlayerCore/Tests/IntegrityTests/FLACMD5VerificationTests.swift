//
//  FLACMD5VerificationTests.swift
//  MacAMP PlayerCore — IntegrityTests
//
//  Every fixture is encoded in-test by `FLACFixtureWriter`, so libFLAC's own
//  MD5 of the samples it was handed is the oracle every assertion is measured
//  against. No external tool runs, and no audio binary is committed.
//

import AVFAudio
import Decoding
import Foundation
import Services
import Testing

@Suite("FLAC stream MD5 verification")
struct FLACMD5VerificationTests {
    // MARK: Happy path

    @Test("An encoder-generated stream verifies as a match")
    func encodedStreamVerifiesAsMatch() async throws {
        try await withFixture(FLACFixtureSpec()) { url in
            let result = try await IntegrityCheckService().verifyFLAC(url: url)
            #expect(result == .match)
            #expect(result.isMatch)
        }
    }

    @Test("A 24-bit stream verifies as a match")
    func twentyFourBitStreamVerifiesAsMatch() async throws {
        var spec = FLACFixtureSpec()
        spec.bitsPerSample = 24
        try await withFixture(spec) { url in
            let result = try await IntegrityCheckService().verifyFLAC(url: url)
            #expect(result == .match)
        }
    }

    @Test("A mono stream verifies as a match")
    func monoStreamVerifiesAsMatch() async throws {
        var spec = FLACFixtureSpec()
        spec.channelCount = 1
        try await withFixture(spec) { url in
            let result = try await IntegrityCheckService().verifyFLAC(url: url)
            #expect(result == .match)
        }
    }

    // MARK: Mismatch

    @Test("A byte-flipped checksum reports a mismatch")
    func flippedChecksumByteReportsMismatch() async throws {
        try await withFixture(FLACFixtureSpec()) { url in
            let pristine = try FLACStreamInfo.storedMD5(of: url)
            let flipped = url.deletingLastPathComponent().appendingPathComponent("flipped.flac")
            try FLACStreamInfo.copy(url, to: flipped, flippingMD5ByteAt: 7)

            let result = try await IntegrityCheckService().verifyFLAC(url: flipped)
            guard case let .mismatch(stored, computed) = result else {
                Issue.record("expected .mismatch, got \(result)")
                return
            }
            #expect(stored != computed)
            // The audio was untouched, so the DECODE half must still reproduce
            // the original checksum — only the comparison changed.
            #expect(computed == pristine)
        }
    }

    @Test("A stream carrying another stream's checksum reports a mismatch")
    func graftedChecksumReportsMismatch() async throws {
        try await withFixture(FLACFixtureSpec()) { first in
            var otherSpec = FLACFixtureSpec()
            otherSpec.seed = 2
            let second = first.deletingLastPathComponent().appendingPathComponent("second.flac")
            try FLACFixtureWriter.write(otherSpec, to: second)

            let secondChecksum = try FLACStreamInfo.storedMD5(of: second)
            let firstChecksum = try FLACStreamInfo.storedMD5(of: first)
            #expect(secondChecksum != firstChecksum)

            let grafted = first.deletingLastPathComponent().appendingPathComponent("grafted.flac")
            try FLACStreamInfo.copy(first, to: grafted, replacingMD5: secondChecksum)

            let result = try await IntegrityCheckService().verifyFLAC(url: grafted)
            guard case let .mismatch(stored, computed) = result else {
                Issue.record("expected .mismatch, got \(result)")
                return
            }
            #expect(stored == secondChecksum)
            #expect(computed == firstChecksum)
        }
    }

    // MARK: No stored checksum

    @Test("A zeroed checksum field reports no stored MD5")
    func zeroedChecksumReportsNoStoredMD5() async throws {
        try await withFixture(FLACFixtureSpec()) { url in
            let pristine = try FLACStreamInfo.storedMD5(of: url)
            let blanked = url.deletingLastPathComponent().appendingPathComponent("blanked.flac")
            let zeros = Data(repeating: 0, count: FLACStreamInfo.md5Range.count)
            try FLACStreamInfo.copy(url, to: blanked, replacingMD5: zeros)

            let result = try await IntegrityCheckService().verifyFLAC(url: blanked)
            guard case let .noStoredMD5(computed) = result else {
                Issue.record("expected .noStoredMD5, got \(result)")
                return
            }
            #expect(!result.isMatch)
            // The stream is still decoded in full, exactly as `flac -t` does.
            #expect(computed == pristine)
        }
    }

    // MARK: Streaming discipline

    @Test("The digest does not depend on the decode window size")
    func windowSizeDoesNotChangeTheDigest() async throws {
        try await withFixture(FLACFixtureSpec()) { url in
            for window in [AVAudioFrameCount(1), 337, 4096, 65536] {
                let service = IntegrityCheckService(windowFrames: window)
                let result = try await service.verifyFLAC(url: url)
                #expect(result == .match, "window \(window)")
            }
        }
    }

    // MARK: Refusals

    @Test("A stream with no FLAC checksum is refused rather than judged")
    func nonFLACStreamIsRefused() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("tone.wav")
            try writeWAV(to: url)
            await #expect(throws: FLACIntegrityError.notFLAC(url: url)) {
                try await IntegrityCheckService().verifyFLAC(url: url)
            }
        }
    }

    @Test("An unopenable file surfaces as unreadable")
    func missingFileIsUnreadable() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("absent.flac")
            let result = await Result { try await IntegrityCheckService().verifyFLAC(url: url) }
            guard case let .failure(error) = result,
                  case .unreadable = error as? FLACIntegrityError
            else {
                Issue.record("expected .unreadable, got \(result)")
                return
            }
        }
    }

    // MARK: Bridge seam

    @Test("The Decoding bridge publishes the STREAMINFO checksum verbatim")
    func bridgePublishesStoredChecksum() async throws {
        try await withFixture(FLACFixtureSpec()) { url in
            let decoder = try SFBDecoderProvider().makeDecoder(for: url)
            let published = try #require((decoder as? any FLACStreamMD5Providing)?.flacStreamMD5)
            #expect(published.count == 16)
            #expect(try published == (FLACStreamInfo.storedMD5(of: url)))
        }
    }

    @Test("A non-FLAC decoder publishes no checksum")
    func bridgePublishesNothingForNonFLAC() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("tone.wav")
            try writeWAV(to: url)
            let decoder = try SFBDecoderProvider().makeDecoder(for: url)
            #expect((decoder as? any FLACStreamMD5Providing)?.flacStreamMD5 == nil)
        }
    }
}

// MARK: - Harness

private extension FLACMD5VerificationTests {
    func withFixture(_ spec: FLACFixtureSpec, _ body: (URL) async throws -> Void) async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("fixture.flac")
            try FLACFixtureWriter.write(spec, to: url)
            try await body(url)
        }
    }

    func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// A tiny 16-bit WAV, written through `AVAudioFile` so the non-FLAC paths
    /// are exercised against a real decodable stream rather than junk bytes.
    func writeWAV(to url: URL) throws {
        let spec = FLACFixtureSpec()
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: spec.sampleRate,
            channels: AVAudioChannelCount(spec.channelCount)
        ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(spec.frameCount))
        else {
            throw FLACFixtureError.unconstructibleFormat
        }
        buffer.frameLength = AVAudioFrameCount(spec.frameCount)
        let planar = FLACFixtureWriter.samples(spec)
        guard let channels = buffer.floatChannelData else { throw FLACFixtureError.missingBufferData }
        for channel in 0 ..< spec.channelCount {
            for frame in 0 ..< spec.frameCount {
                channels[channel][frame] = Float(planar[channel][frame]) / Float(spec.fullScale + 1)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do {
            self = try await .success(body())
        } catch {
            self = .failure(error)
        }
    }
}
