import Foundation
import Services

/// Locates the committed `.cue` fixtures next to this test target.
///
/// `Fixtures/` is excluded from the build (see Package.swift) and loaded by path via
/// `#filePath`, mirroring the Decoding / Metadata / PlaylistIO fixture pattern. See
/// `Fixtures/README.md` for what each sheet proves.
enum CueFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func contents(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }
}

/// A locator that reports every `FILE` operand as present, without touching disk.
///
/// The parser's grammar is what these tests exercise; committing four albums of audio to
/// prove it would be absurd. The one test that needs real filesystem behaviour uses the
/// production `FileManagerCueAudioFileLocator` instead.
struct StubCueAudioFileLocator: CueAudioFileLocating {
    /// Names this locator refuses, so a test can drive one dead reference among many.
    var missing: Set<String> = []

    func locate(fileName: String, relativeTo directory: URL) -> String? {
        guard !missing.contains(fileName) else {
            return nil
        }
        return directory.appendingPathComponent(fileName).path
    }
}

/// The parts of a ``CueTrack`` that define its SEGMENTATION, with provenance flags
/// deliberately left out.
///
/// The EAC equivalence test turns on exactly this distinction: the normalized variant
/// and its compliant twin must agree on every field here, while still disagreeing on
/// `hasAppendedGapInPriorFile` — which is a record of where the sheet came from, not of
/// what plays.
struct CueSegment: Equatable, CustomStringConvertible {
    let number: Int
    let filePath: String
    let startFrame: Int
    let endFrame: Int?
    let title: String?
    let performer: String?

    var description: String {
        "track \(number) [\(startFrame)..\(endFrame.map(String.init) ?? "EOF")) in \(fileName)"
    }

    var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

extension CueTrack {
    var segment: CueSegment {
        CueSegment(
            number: number,
            filePath: filePath,
            startFrame: startFrame,
            endFrame: endFrame,
            title: title,
            performer: performer
        )
    }
}
