// FFProgressFileTailer coverage — the pure half of conversion progress.
//
// Every block below is written out the way ffmpeg writes one, independently of the
// production key constants, for the same double-entry reason `YtDlpCommandBuilderTests`
// restates the quality table: a fixture built from `FFProgressFileTailer.outTimeKey`
// would keep agreeing with whatever that constant became, including `out_time_ms`.
//
// The real-download QA cannot make these claims. A fast conversion legitimately emits a
// single terminal block (the todo-8 probe measured flac finishing at 474x realtime), so
// "a transcode reports a fraction" is flaky by construction against a live engine and is
// asserted here, from synthetic contents, instead.
import Foundation
import Services
import Testing

@Suite("ffmpeg progress tailer")
struct FFProgressFileTailerTests {
    /// A round denominator: 100 s means `out_time_us` is simply the percentage × 1e6.
    static let duration: Double = 100

    static func block(microseconds: Int, terminator: String = "continue") -> String {
        """
        bitrate=1575.9kbits/s
        total_size=3244032
        out_time_us=\(microseconds)
        out_time_ms=\(microseconds)
        out_time=00:00:16.470000
        speed= 474x
        progress=\(terminator)

        """
    }

    // MARK: - The specified sequence

    /// The plan's acceptance sequence, read the way the poller reads it: the same file
    /// growing, sampled three times.
    @Test("a growing progress file reports 0.4, then 0.8, then nil at the terminal block")
    func aGrowingFileReportsItsSamplesThenNil() throws {
        var contents = Self.block(microseconds: 40_000_000)
        let first = FFProgressFileTailer.fraction(inContents: contents, durationSeconds: Self.duration)

        contents += Self.block(microseconds: 80_000_000)
        let second = FFProgressFileTailer.fraction(inContents: contents, durationSeconds: Self.duration)

        contents += Self.block(microseconds: 100_000_000, terminator: "end")
        let terminal = FFProgressFileTailer.fraction(inContents: contents, durationSeconds: Self.duration)

        #expect(try #require(first).isApproximately(0.4))
        #expect(try #require(second).isApproximately(0.8))
        #expect(terminal == nil)
    }

    /// The terminal block carries the FULL duration, so it is the one sample that would
    /// compute to exactly 1.0. It must not: `EmbedThumbnail`, `Metadata` and `MoveFiles`
    /// still run after it, and a bar pinned at 100% through them is the lie this removes.
    @Test("the terminal block reports nil even though it computes to 1.0")
    func theTerminalBlockReportsNilRatherThanOne() {
        let contents = Self.block(microseconds: 100_000_000, terminator: "end")

        #expect(FFProgressFileTailer.fraction(inContents: contents, durationSeconds: Self.duration) == nil)
        #expect(
            FFProgressFileTailer.fraction(
                inContents: Self.block(microseconds: 100_000_000),
                durationSeconds: Self.duration
            ) != nil
        )
    }

    // MARK: - No denominator

    /// A failed `-J` prefetch leaves the row with no duration. Every sample in the file
    /// is then unusable, and the honest answer is `nil` forever — never an estimate.
    @Test("an unknown duration reports nil however many samples arrived")
    func anUnknownDurationReportsNilThroughout() {
        let contents = Self.block(microseconds: 40_000_000) + Self.block(microseconds: 80_000_000)

        #expect(FFProgressFileTailer.fraction(inContents: contents, durationSeconds: nil) == nil)
        #expect(FFProgressFileTailer.fraction(inContents: contents, durationSeconds: 0) == nil)
        #expect(FFProgressFileTailer.fraction(inContents: contents, durationSeconds: -5) == nil)
        #expect(FFProgressFileTailer.fraction(inContents: contents, durationSeconds: .nan) == nil)
    }

    // MARK: - Reading the right key

    /// `out_time_ms` is present in every block and carries the SAME MICROSECOND value —
    /// ffmpeg's suffix is a misnomer. A tailer that read it would be right by accident
    /// today and wrong the day it is fixed, so this pins that only `out_time_us` counts.
    @Test("a block with only out_time_ms reports nothing")
    func onlyOutTimeMicrosecondsIsRead() {
        let contents = """
        out_time_ms=40000000
        progress=continue

        """

        #expect(FFProgressFileTailer.fraction(inContents: contents, durationSeconds: Self.duration) == nil)
    }

    // MARK: - Robustness

    /// The file is sampled WHILE ffmpeg writes it, so one torn or unparseable line must
    /// not discard the block around it.
    @Test("malformed lines are ignored individually")
    func malformedLinesAreIgnored() throws {
        let contents = """
        this line has no separator at all
        =leading separator
        out_time_us=N/A
        out_time_us=-9223372036854775808
        out_time_us=40000000
        progress=continue

        """

        let fraction = FFProgressFileTailer.fraction(inContents: contents, durationSeconds: Self.duration)

        #expect(try #require(fraction).isApproximately(0.4))
    }

    /// A sample is committed only once its own `progress=` line has been read, so an
    /// unterminated trailing block is dropped whole. Without that, the torn `15` of a
    /// half-written `150093792` would snap the bar to ~0 for a frame.
    @Test("an unterminated trailing block is discarded, keeping the last complete one")
    func aTornTrailingBlockIsDiscarded() throws {
        let contents = Self.block(microseconds: 80_000_000) + """
        bitrate=1575.9kbits/s
        out_time_us=15
        """

        let fraction = FFProgressFileTailer.fraction(inContents: contents, durationSeconds: Self.duration)

        #expect(try #require(fraction).isApproximately(0.8))
    }

    @Test("an empty or sample-free file reports nil")
    func anEmptyFileReportsNil() {
        #expect(FFProgressFileTailer.fraction(inContents: "", durationSeconds: Self.duration) == nil)
        #expect(
            FFProgressFileTailer.fraction(inContents: "progress=continue\n", durationSeconds: Self.duration) == nil
        )
    }

    /// A source whose real length exceeds the `-J` duration (a live stream, a rounded
    /// figure) must not drive a progress bar past its end.
    @Test("a sample beyond the reported duration is clamped to 1")
    func anOverlongSampleIsClamped() throws {
        let contents = Self.block(microseconds: 250_000_000)

        let fraction = FFProgressFileTailer.fraction(inContents: contents, durationSeconds: Self.duration)

        #expect(try #require(fraction) == 1)
    }

    /// ffmpeg writes `\n`, but a reader that assumed it would silently see one enormous
    /// line if that ever changed — and report nothing at all.
    @Test("carriage returns separate lines too")
    func carriageReturnsSeparateLines() throws {
        let contents = "out_time_us=40000000\r\nprogress=continue\r\n"

        let fraction = FFProgressFileTailer.fraction(inContents: contents, durationSeconds: Self.duration)

        #expect(try #require(fraction).isApproximately(0.4))
    }
}

private extension Double {
    func isApproximately(_ other: Double) -> Bool {
        abs(self - other) < 1e-9
    }
}
