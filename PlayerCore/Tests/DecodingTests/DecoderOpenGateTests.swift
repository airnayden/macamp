// DecoderOpenGateTests — the one invariant that stops the mpg123 first-init race.
//
// The crash this guards against is a SIGBUS inside `INT123_frame_init_par`, hit
// when several threads construct their first MP3 decoder at the same instant. It
// cannot be asserted by a "does not crash" test: a SIGBUS takes the whole test
// process down, so a regression would read as an infrastructure failure rather
// than a red assertion. What IS assertable — and is exactly the property the fix
// buys — is that no two opens are ever inside the backend at the same time.
//
// `.serialized` because the recorder measures wall-clock overlap: another suite
// opening a decoder concurrently would land in this suite's window.
import AVFAudio
import Decoding
import Foundation
import Testing

@Suite(.serialized)
struct DecoderOpenGateTests {
    /// Enough openers to saturate every core on a CI machine and then some, so
    /// the ungated control really does overlap rather than accidentally serialise.
    static let openerCount = 16

    /// Opens per opener. 16 × 20 = 320 total, which is both a real stress and
    /// fast (each open only parses an MP3 header).
    static let iterationsPerOpener = 20

    @Test("concurrent decoder opens through the gate never overlap")
    func concurrentOpensNeverOverlap() async {
        let recorder = OpenConcurrencyRecorder()
        let gate = DecoderOpenGate(
            willOpen: { recorder.willOpen() },
            didOpen: { recorder.didOpen() }
        )
        let provider = SFBDecoderProvider()
        let url = TestFixtures.mp3

        let validFormats = await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< Self.openerCount {
                group.addTask {
                    var valid = 0
                    for _ in 0 ..< Self.iterationsPerOpener {
                        let decoder = try? await gate.open(url, with: provider)
                        if let decoder, decoder.processingFormat.sampleRate > 0 { valid += 1 }
                    }
                    return valid
                }
            }
            return await group.reduce(0, +)
        }

        #expect(recorder.maxObservedConcurrency == 1, "two decoder opens overlapped")
        #expect(validFormats == Self.openerCount * Self.iterationsPerOpener)
    }

    /// The gate must not swallow or reshape a backend failure — a call site that
    /// maps `DecodingError` onto its own domain still has to see the original.
    @Test("a failing open propagates its error unchanged")
    func failingOpenPropagatesItsError() async throws {
        let gate = DecoderOpenGate()
        await #expect(throws: DecodingError.self) {
            _ = try await gate.open(TestFixtures.url("does-not-exist.mp3"), with: SFBDecoderProvider())
        }
    }
}

// MARK: - Recorder

/// Counts how many opens are inside the backend at the same instant.
///
/// `@unchecked Sendable` over an `NSLock`, the `ConcurrencyRecordingExtractor`
/// shape from the analysis suites: the counters are touched from every opener
/// task, so they need a lock rather than actor isolation (an actor hop would
/// itself serialise the thing under measurement).
final class OpenConcurrencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var observedMax = 0

    func willOpen() {
        lock.withLock {
            inFlight += 1
            observedMax = max(observedMax, inFlight)
        }
    }

    func didOpen() {
        lock.withLock { inFlight -= 1 }
    }

    /// The greatest number of opens ever in flight at the same instant.
    var maxObservedConcurrency: Int {
        lock.withLock { observedMax }
    }
}
