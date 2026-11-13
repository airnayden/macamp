// macamp-cli — a headless, hardware-free audio test harness CLI.
//
// Subcommands:
//   render  <wav>                              report duration + peak dBFS
//   analyze <wav> [--expect-peak-hz N]
//                 [--tolerance-bins N]          assert dominant frequency, exit 0/non-zero
//   synth   --tone <Hz> --rate <Hz>
//                 --seconds <N> --out <path>    write a sine WAV (for CLI QA)
//   decode  <file>                             decode any SFB-supported file to PCM,
//                                              report format; exit non-zero (typed) on bad input
//   formats                                    list every supported audio format / extension
//
// render/analyze/synth route through the offline render harness; decode/formats
// exercise the Decoding module (SFBAudioEngine). No real hardware is ever touched.
import AVFAudio
import Decoding
import Foundation
import PlayerCoreTestSupport

// MARK: - tiny stderr / exit helpers

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func printUsage() {
    let usage = """
    macamp-cli — headless offline audio harness

    USAGE:
      macamp-cli render  <wav-file>
      macamp-cli analyze <wav-file> [--expect-peak-hz <Hz>] [--tolerance-bins <N>]
      macamp-cli synth   --tone <Hz> --rate <Hz> --seconds <N> --out <path>
      macamp-cli decode  <file>
      macamp-cli formats
      macamp-cli seed    --tracks <N> --db <path> [--batch <N>]
      macamp-cli search  --db <path> "<query>" [--measure] [--limit <N>]
      macamp-cli tags    <file> [--print-sortkey] [--has-art] [--print-replaygain]
      macamp-cli scan    <dir> --db <path> [--json] [--chunk <N>]
      macamp-cli scan    --synthetic <N> --db <path> [--measure] [--memory-ceiling] [--json]
      macamp-cli loudness-mem --count <N> [--seconds <S>] [--rate <Hz>] [--page <N>]
                              [--dir <path>] [--keep] [--json]
      macamp-cli zeroalloc [--iterations <N>] [--pulls <N>] [--frames <N>] [--json]
    """
    print(usage)
}

// MARK: - flag parsing (hand-rolled; no external dependencies)

/// Returns the value following `--name`, if present.
func flagValue(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func doubleFlag(_ name: String, in args: [String]) -> Double? {
    flagValue(name, in: args).flatMap(Double.init)
}

func intFlag(_ name: String, in args: [String]) -> Int? {
    flagValue(name, in: args).flatMap(Int.init)
}

// MARK: - subcommands

func runRender(_ args: [String]) {
    guard let path = args.first else { fail("render requires a <wav-file> argument", code: 2) }
    let url = URL(fileURLWithPath: path)
    do {
        let buffer = try OfflineRenderHarness.renderFile(url: url)
        let seconds = Analysis.duration(buffer: buffer)
        let peak = Analysis.peakDBFS(buffer: buffer)
        let rms = Analysis.dBFS(buffer: buffer)
        print("file:        \(url.lastPathComponent)")
        print("sampleRate:  \(buffer.format.sampleRate) Hz")
        print("channels:    \(buffer.format.channelCount)")
        print("frames:      \(buffer.frameLength)")
        print(String(format: "duration:    %.4f s", seconds))
        print(String(format: "peak:        %.2f dBFS", peak))
        print(String(format: "rms:         %.2f dBFS", rms))
        print("clipped:     \(Analysis.isClipped(buffer: buffer))")
    } catch {
        fail("\(error)")
    }
}

func runAnalyze(_ args: [String]) {
    guard let path = args.first else { fail("analyze requires a <wav-file> argument", code: 2) }
    let url = URL(fileURLWithPath: path)
    let toleranceBins = intFlag("--tolerance-bins", in: args) ?? 1
    let fftSize = 4096

    do {
        let buffer = try OfflineRenderHarness.renderFile(url: url)
        let result = Analysis.peakBin(buffer: buffer, fftSize: fftSize)
        print("peakBin:     \(result.bin)")
        print(String(format: "peakFreq:    %.2f Hz", result.frequency))
        print(String(format: "peak:        %.2f dBFS", Analysis.peakDBFS(buffer: buffer)))

        guard let expectHz = doubleFlag("--expect-peak-hz", in: args) else {
            // No expectation requested: just report.
            return
        }
        let expectedBin = Int((expectHz * Double(fftSize) / buffer.format.sampleRate).rounded())
        let deltaBins = abs(result.bin - expectedBin)
        print("expectBin:   \(expectedBin) (\(expectHz) Hz)")
        print("deltaBins:   \(deltaBins) (tolerance \(toleranceBins))")
        if deltaBins <= toleranceBins {
            print("RESULT:      PASS")
        } else {
            fail(
                "peak bin \(result.bin) is \(deltaBins) bins from expected \(expectedBin) "
                    + "(tolerance \(toleranceBins))",
                code: 3
            )
        }
    } catch {
        fail("\(error)")
    }
}

func runSynth(_ args: [String]) {
    guard let tone = doubleFlag("--tone", in: args) else { fail("synth requires --tone <Hz>", code: 2) }
    guard let rate = doubleFlag("--rate", in: args) else { fail("synth requires --rate <Hz>", code: 2) }
    guard let seconds = doubleFlag("--seconds", in: args) else { fail("synth requires --seconds <N>", code: 2) }
    guard let out = flagValue("--out", in: args) else { fail("synth requires --out <path>", code: 2) }

    let url = URL(fileURLWithPath: out)
    let format = SignalGenerators.monoFormat(sampleRate: rate)
    do {
        // Dogfood the harness: render the tone offline, then persist to WAV.
        let buffer = try OfflineRenderHarness.render(format: format, duration: seconds) { engine in
            let source = SignalGenerators.sine(frequency: tone, sampleRate: rate)
            engine.attach(source)
            return source
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        print("wrote \(buffer.frameLength) frames (\(seconds)s @ \(rate) Hz, \(tone) Hz tone) -> \(out)")
    } catch {
        fail("\(error)")
    }
}

/// Maps a typed ``DecodingError`` to a distinct non-zero exit status so QA can
/// assert *which* failure occurred from the shell.
func exitCode(for error: DecodingError) -> Int32 {
    switch error {
    case .unsupportedFormat: 10
    case .corruptedFile: 11
    case .truncated: 12
    case .ioError: 13
    case .unsupportedSampleRate: 14
    }
}

/// A short sample-format label (e.g. `float32`, `int16`) for an `AVAudioFormat`,
/// inspecting the raw ASBD for the `pcmFormatOther` (packed-integer) case.
func sampleFormatLabel(_ format: AVAudioFormat) -> String {
    switch format.commonFormat {
    case .pcmFormatFloat32: "float32"
    case .pcmFormatFloat64: "float64"
    case .pcmFormatInt16: "int16"
    case .pcmFormatInt32: "int32"
    default:
        {
            let asbd = format.streamDescription.pointee
            guard asbd.mBitsPerChannel > 0 else { return "compressed" }
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            return "\(isFloat ? "float" : "int")\(asbd.mBitsPerChannel)"
        }()
    }
}

func runDecode(_ args: [String]) {
    guard let path = args.first else { fail("decode requires a <file> argument", code: 2) }
    let url = URL(fileURLWithPath: path)
    let provider = SFBDecoderProvider()
    do {
        let decoder = try provider.makeDecoder(for: url)
        let format = decoder.processingFormat
        let buffer = try decoder.decodeAll()
        print("file:         \(url.lastPathComponent)")
        print("decoder:      SFBDecoderProvider")
        if let source = decoder.sourceFormat {
            print("sourceFormat: \(Int(source.sampleRate)) Hz, \(source.channelCount) ch, \(sampleFormatLabel(source))")
        }
        print(
            "processing:   \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(sampleFormatLabel(format)) (-> float32)"
        )
        print("frames:       \(buffer.frameLength)")
        print(String(format: "duration:     %.4f s", Analysis.duration(buffer: buffer)))
        print(String(format: "peak:         %.2f dBFS", Analysis.peakDBFS(buffer: buffer)))
        print(String(format: "rms:          %.2f dBFS", Analysis.dBFS(buffer: buffer)))
        print("RESULT:       OK")
    } catch let error as DecodingError {
        fail("\(error)", code: exitCode(for: error))
    } catch {
        fail("\(error)")
    }
}

func runFormats(_ args: [String]) {
    _ = args
    let extensions = SFBDecoderProvider.supportedPathExtensions
    let families: [(name: String, extensions: [String])] = [
        ("FLAC", ["flac"]),
        ("MP3", ["mp3"]),
        ("ALAC / AAC", ["m4a", "m4b", "aac", "mp4"]),
        ("Ogg Vorbis", ["ogg", "oga"]),
        ("Opus", ["opus"]),
        ("WavPack", ["wv"]),
        ("Monkey's Audio (APE)", ["ape"]),
        ("Musepack", ["mpc"]),
        ("WAV", ["wav"]),
        ("AIFF", ["aif", "aiff", "aifc"]),
        ("DSD", ["dsf", "dff", "dsdiff"]),
        ("Tracker modules", ["mod", "xm", "it", "s3m"]),
    ]

    print("MacAMP supported audio formats (Decoding module / SFBAudioEngine):")
    print("")
    for family in families {
        let present = family.extensions.filter { extensions.contains($0) }
        let mark = present.isEmpty ? "-" : "+"
        let shown = present.isEmpty ? family.extensions : present
        let label = family.name.padding(toLength: 22, withPad: " ", startingAt: 0)
        print("  [\(mark)] \(label) \(shown.joined(separator: ", "))")
    }

    print("")
    print("path extensions (\(extensions.count)): \(extensions.sorted().joined(separator: ", "))")
    let mimeTypes = SFBDecoderProvider.supportedMIMETypes.sorted()
    print("MIME types (\(mimeTypes.count)): \(mimeTypes.joined(separator: ", "))")
}

// MARK: - entry point

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    printUsage()
    exit(2)
}

let rest = Array(arguments.dropFirst())

switch command {
case "render": runRender(rest)
case "analyze": runAnalyze(rest)
case "synth": runSynth(rest)
case "decode": runDecode(rest)
case "formats": runFormats(rest)
case "seed": runSeed(rest)
case "search": runSearch(rest)
case "tags": runTags(rest)
case "scan": runScan(rest)
case "loudness-mem": runLoudnessMemory(rest)
case "zeroalloc": runZeroAlloc(rest)
case "-h", "--help", "help": printUsage()
default:
    printUsage()
    fail("unknown subcommand: \(command)", code: 2)
}
