import CryptoKit
import Foundation

/// Scratch-file helpers shared by the ReplayGain tag-writing suites.
///
/// Every test operates on a throw-away duplicate in its own temp directory — the
/// committed fixtures are never mutated.
enum Scratch {
    /// A file's identity for "was it touched?" assertions: content hash plus the
    /// modification timestamp, so a rewrite that happens to produce identical bytes
    /// would still be caught.
    struct Identity: Equatable {
        let sha256: String
        let modified: Date?
    }

    static func withWorkingCopy(
        of fixture: URL,
        perform body: (URL) throws -> Void
    ) throws {
        try withScratchDirectory { scratch in
            let copy = scratch.appendingPathComponent(fixture.lastPathComponent)
            try FileManager.default.copyItem(at: fixture, to: copy)
            try body(copy)
        }
    }

    /// Writes `bytes` to a scratch file named `<uuid>.<ext>` and hands it over.
    ///
    /// The content is deliberately arbitrary: the refusal paths under test are
    /// decided from the path extension before the file is ever opened, so a real
    /// encode would prove less, not more.
    static func withStubFile(
        pathExtension: String,
        bytes: Data = Data("macamp replaygain refusal fixture".utf8),
        perform body: (URL) throws -> Void
    ) throws {
        try withScratchDirectory { scratch in
            let url = scratch.appendingPathComponent("stub-\(UUID().uuidString).\(pathExtension)")
            try bytes.write(to: url)
            try body(url)
        }
    }

    static func identity(of url: URL) throws -> Identity {
        let data = try Data(contentsOf: url)
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        return Identity(
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            modified: modified
        )
    }

    private static func withScratchDirectory(perform body: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory
            .appendingPathComponent("macamp-rg-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            // A 0444 test file must be made writable again before the tree can go.
            if let entries = try? manager.contentsOfDirectory(atPath: scratch.path) {
                for entry in entries {
                    try? manager.setAttributes(
                        [.posixPermissions: 0o644],
                        ofItemAtPath: scratch.appendingPathComponent(entry).path
                    )
                }
            }
            try? manager.removeItem(at: scratch)
        }
        try body(scratch)
    }
}
