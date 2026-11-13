// Which STREAM the engine writes each MacAMP sentinel to, asserted end to end through
// the driver rather than against the parser in isolation.
//
// `YtDlpProgressParserTests` already feeds `MACAMP-PP|` strings straight in and asserts
// `.postProcessing` — and passed the whole time the state was UNREACHABLE in
// production, because the driver read stdout only and the engine writes that template
// to stderr. A parser test cannot see that; nothing in it ever asks which stream a line
// arrives on. So every case here drives the real `DownloadEngineRun.transfer` loop
// through `FakeToolProcessRunner`, with the two streams SPLIT the way one measured run
// actually split them.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("Download engine stream routing")
struct DownloadStreamRoutingTests {
    @Test("a post-process sentinel delivered on STDERR reaches the row as postProcessing")
    func stderrPostProcessSentinelIsParsed() async throws {
        let harness = harness(download: ToolProcessScript(
            lines: [
                .stdout(DownloadFixture.quarterProgress),
                .stderr("MACAMP-PP|started|ExtractAudio"),
                .stdout(DownloadFixture.fileLine),
            ],
            termination: .success
        ))

        let states = try await harness.drainOneRow()

        #expect(states.contains(.postProcessing(fraction: nil)))
    }

    /// The whole measured capture: eight transfer samples and a `finished` sample on
    /// stdout, eight post-process sentinels on stderr, then the file line on stdout.
    @Test("the real captured run finishes, having passed through postProcessing")
    func realCaptureReachesFinishedThroughPostProcessing() async throws {
        let harness = harness(download: DownloadFixture.realCaptureScript)

        let states = try await harness.drainOneRow()

        let phase = try #require(states.firstIndex(of: .postProcessing(fraction: nil)))
        let transferred = states.contains(where: \.isDownloading)
        #expect(states.first == .queued)
        #expect(states.dropFirst().first == .fetchingMetadata)
        #expect(transferred)
        #expect(states.last == .finished(fileURL: DownloadStreamRoutingTests.finishedURL))
        #expect(phase < states.count - 1)
    }

    /// The consequence of reading stderr: `.postProcessing` now arrives AFTER the last
    /// `MACAMP-P|` sample the other stream had buffered. Publishing that straggler would
    /// snap the pane back from "Converting audio…" to a full download bar.
    @Test("a progress sample arriving after post-processing never rewinds the row")
    func lateProgressDoesNotRewindPostProcessing() async throws {
        let harness = harness(download: ToolProcessScript(
            lines: [
                .stdout(DownloadFixture.quarterProgress),
                .stderr("MACAMP-PP|started|ExtractAudio"),
                .stdout(DownloadFixture.halfProgress),
                .stdout(DownloadFixture.finishedProgress),
                .stdout(DownloadFixture.fileLine),
            ],
            termination: .success
        ))

        let states = try await harness.drainOneRow()

        let phase = try #require(states.firstIndex(of: .postProcessing(fraction: nil)))
        let rewound = states[phase...].contains(where: \.isDownloading)
        #expect(!rewound)
        #expect(states.last == .finished(fileURL: DownloadStreamRoutingTests.finishedURL))
    }

    /// The sentinels are the LAST thing written to stderr, so an unfiltered "keep every
    /// stderr line" rule hands a failed download `MACAMP-PP|finished|MoveFiles` as its
    /// diagnostic — wire format that reads like success, in place of the real error.
    @Test("a real ERROR line survives the post-process sentinels that follow it")
    func errorLineSurvivesTrailingSentinels() async throws {
        let errorLine = "ERROR: [youtube] jNQXAC9IVRw: Video unavailable"
        let harness = harness(download: ToolProcessScript(
            lines: [.stderr(errorLine)]
                + DownloadFixture.postProcessStderrLines.map(ToolOutputEvent.stderr),
            termination: ProcessTermination(status: 1, reason: .normalExit)
        ))

        let states = try await harness.drainOneRow()

        #expect(states.last == .failed(.downloadFailed(detail: errorLine)))
    }

    /// `isSentinel` is a PREFIX test, not `event(from:) != nil` — a sentinel with a
    /// malformed payload is still MacAMP's own output and still not a diagnostic.
    @Test("a malformed sentinel on stderr is excluded from the diagnostic too")
    func malformedSentinelIsNotADiagnostic() async throws {
        let errorLine = "ERROR: unable to write data"
        let harness = harness(download: ToolProcessScript(
            lines: [.stderr(errorLine), .stderr("MACAMP-PP|truncated")],
            termination: ProcessTermination(status: 1, reason: .normalExit)
        ))

        let states = try await harness.drainOneRow()

        #expect(states.last == .failed(.downloadFailed(detail: errorLine)))
    }
}

// MARK: - Rig

private extension DownloadStreamRoutingTests {
    static let finishedURL = URL(fileURLWithPath: DownloadFixture.finishedPath)

    /// A harness whose first spawn is the metadata prefetch every download makes and
    /// whose second is `script` — the run under test.
    func harness(download script: ToolProcessScript) -> DownloadQueueHarness {
        DownloadQueueHarness(scripts: [DownloadFixture.infoScript(), script])
    }
}

private extension DownloadQueueHarness {
    /// Enqueues one video, waits for it to settle, and returns every state it published.
    func drainOneRow() async throws -> [DownloadState] {
        let url = try downloadTestURL(DownloadFixture.watchURL)
        _ = await service.enqueue(urls: [url])
        await waitForTerminals(1)
        return try recorder.states(of: firstEnqueuedID())
    }
}

private extension DownloadState {
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}
