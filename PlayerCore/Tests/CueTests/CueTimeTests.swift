// The 75 fps timecode arithmetic every cue frame value rests on, plus the lexical rules
// that decide what counts as a timecode at all.
import Foundation
import Services
import Testing

/// One `MM:SS:FF` row: the text and the frame count it must produce.
struct CueTimecodeCase: CustomStringConvertible {
    let timecode: String
    let frames: Int?

    var description: String {
        "\(timecode) -> \(frames.map(String.init) ?? "refused")"
    }
}

@Suite("CUE timecodes")
struct CueTimeTests {
    static let cases: [CueTimecodeCase] = [
        CueTimecodeCase(timecode: "00:00:00", frames: 0),
        CueTimecodeCase(timecode: "00:00:01", frames: 1),
        CueTimecodeCase(timecode: "00:01:00", frames: 75),
        CueTimecodeCase(timecode: "00:02:00", frames: 150),
        CueTimecodeCase(timecode: "00:02:33", frames: 183),
        CueTimecodeCase(timecode: "01:00:00", frames: 4500),
        CueTimecodeCase(timecode: "04:41:25", frames: 21100),
        CueTimecodeCase(timecode: "04:43:00", frames: 21225),
        CueTimecodeCase(timecode: "05:20:40", frames: 24040),
        CueTimecodeCase(timecode: "05:42:03", frames: 25653),
        CueTimecodeCase(timecode: "08:27:37", frames: 38062),
        CueTimecodeCase(timecode: "12:47:15", frames: 57540),
        CueTimecodeCase(timecode: "79:59:74", frames: 359_999),
        // Three digits of minutes: legal for a non-CD source, and some sheets use it.
        CueTimecodeCase(timecode: "100:00:00", frames: 450_000),
        // SS must be < 60 and FF < 75 — both are counts, not clock digits.
        CueTimecodeCase(timecode: "00:60:00", frames: nil),
        CueTimecodeCase(timecode: "00:00:75", frames: nil),
        CueTimecodeCase(timecode: "00:00", frames: nil),
        CueTimecodeCase(timecode: "00:00:00:00", frames: nil),
        CueTimecodeCase(timecode: "", frames: nil),
        CueTimecodeCase(timecode: "aa:bb:cc", frames: nil),
        CueTimecodeCase(timecode: "00::00", frames: nil),
        CueTimecodeCase(timecode: "-1:00:00", frames: nil),
        // Arabic-Indic digits satisfy `isNumber` but not `Int(_:)` — the ASCII guard is
        // what keeps "parsed" and "convertible" the same predicate.
        CueTimecodeCase(timecode: "٠٠:٠٠:٠٠", frames: nil),
    ]

    @Test("MM:SS:FF converts at 75 frames per second", arguments: cases)
    func timecodeConversion(_ testCase: CueTimecodeCase) {
        #expect(CueTime(timecode: testCase.timecode)?.totalFrames == testCase.frames)
    }

    @Test("A CD frame is exactly 588 samples at 44.1 kHz")
    func samplesAtRedBookRate() {
        #expect(CueTime.samples(frames: 1, sampleRate: 44100) == 588)
        #expect(CueTime.samples(frames: 75, sampleRate: 44100) == 44100)
        #expect(CueTime.samples(frames: 21225, sampleRate: 44100) == 12_480_300)
    }

    @Test("Hi-res rates stay exact because every standard rate divides by 75")
    func samplesAtHighRates() {
        #expect(CueTime.samples(frames: 1, sampleRate: 48000) == 640)
        #expect(CueTime.samples(frames: 1, sampleRate: 96000) == 1280)
        #expect(CueTime.samples(frames: 1, sampleRate: 192_000) == 2560)
        // A long disc at 192 kHz overflows a 32-bit intermediate; this is why the
        // arithmetic is done in Int64.
        #expect(CueTime.samples(frames: 359_999, sampleRate: 192_000) == 921_597_440)
    }

    @Test("Frame counts convert to seconds without a sample rate")
    func secondsFromFrames() {
        #expect(CueTime.seconds(frames: 75) == 1.0)
        #expect(CueTime.seconds(frames: 0) == 0.0)
        #expect(abs(CueTime.seconds(frames: 21225) - 283.0) < 1e-9)
    }

    @Test("Timecodes order by absolute position, not by component")
    func ordering() throws {
        let earlier = try #require(CueTime(timecode: "00:59:74"))
        let later = try #require(CueTime(timecode: "01:00:00"))

        #expect(earlier < later)
        #expect(earlier.totalFrames == later.totalFrames - 1)
    }
}
