import Foundation

/// Locates the committed binary fixtures next to this test target.
///
/// `Fixtures/` is excluded from the build (see Package.swift) and loaded by path
/// via `#filePath`, mirroring the Persistence / DesignSystem fixture pattern.
/// See `Fixtures/README.md` for how each file was generated.
enum TestFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static var wav: URL {
        url("tone.wav")
    }

    static var flac: URL {
        url("tone.flac")
    }

    static var mp3: URL {
        url("tone.mp3")
    }

    static var dsf: URL {
        url("tone.dsf")
    }

    static var dsd128: URL {
        url("tone-dsd128.dsf")
    }

    static var corruptFlac: URL {
        url("corrupt.flac")
    }
}
