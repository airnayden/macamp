// ToolExecutableTreeTests — the tree variant of the executable-hygiene helpers, which
// exists because yt-dlp became a PyInstaller ONE-DIRECTORY tool.
//
// The single-file suite (`ToolExecutableFileTests`) covers the launcher. What is new,
// and what these tests pin, is that the strip reaches the 133-file `_internal/` payload
// beside it: `FileManager.copyItem` PROPAGATES `com.apple.quarantine` into nested files,
// so a tree copied out of a quarantined app bundle arrives with every one of its shared
// libraries flagged — and those are exactly the files the launcher `dlopen`s.
//
// A fixture mirrors that shape (a launcher plus a nested `_internal/` file) rather than
// using the real 124 MB tree, so the suite stays hermetic and runs in milliseconds.
import Foundation
import Services
import Testing

@Suite("Tool executable tree hygiene")
struct ToolExecutableTreeTests {
    @Test("quarantine is stripped from nested files, not just the launcher")
    func stripsQuarantineThroughoutTheTree() throws {
        let tree = try makeTreeFixture()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        for file in [tree.launcher, tree.nestedLibrary] {
            #expect(treeSetQuarantine(on: file) == 0)
        }

        try ToolExecutableFile.makeTreeRunnable(at: tree.root, executable: tree.launcher)

        #expect(!treeHasQuarantine(tree.launcher))
        #expect(!treeHasQuarantine(tree.nestedLibrary), "the _internal/ payload must be stripped too")
    }

    @Test("the launcher is left executable and the tree walk is idempotent")
    func theLauncherBecomesRunnableAndRepeatsCleanly() throws {
        let tree = try makeTreeFixture()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: tree.launcher.path
        )

        // The second call is the one that matters: every strip then answers ENOATTR,
        // which must read as success or a steady-state launch would fail.
        try ToolExecutableFile.makeTreeRunnable(at: tree.root, executable: tree.launcher)
        try ToolExecutableFile.makeTreeRunnable(at: tree.root, executable: tree.launcher)

        let mode = try toolPosixPermissions(of: tree.launcher)
        #expect(mode == 0o755)
        #expect(FileManager.default.isExecutableFile(atPath: tree.launcher.path))
    }

    @Test("the walk finds every regular file and no directories")
    func regularFilesCoversTheWholeTree() throws {
        let tree = try makeTreeFixture()
        defer { try? FileManager.default.removeItem(at: tree.root) }

        let found = try ToolExecutableFile.regularFiles(under: tree.root)

        #expect(Set(found.map(\.lastPathComponent)) == ["yt-dlp_macos", "Python", "libnested.dylib"])
    }

    /// A symlink out of the tree must not be followed — stripping through one would
    /// reach a file the app never copied and does not own.
    @Test("symlinks are not walked")
    func symlinksAreSkipped() throws {
        let tree = try makeTreeFixture()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let outsider = FileManager.default.temporaryDirectory
            .appendingPathComponent("macamp-outsider-\(UUID().uuidString)")
        try Data("outside".utf8).write(to: outsider)
        defer { try? FileManager.default.removeItem(at: outsider) }
        try FileManager.default.createSymbolicLink(
            at: tree.root.appendingPathComponent("link"),
            withDestinationURL: outsider
        )

        let found = try ToolExecutableFile.regularFiles(under: tree.root)

        #expect(!found.contains { $0.lastPathComponent == "link" })
        #expect(found.count == 3)
    }

    /// An absent tree cannot be made runnable. The failure surfaces on the launcher —
    /// `FileManager.enumerator(at:)` reports an empty walk for a missing directory
    /// rather than refusing, so the missing LAUNCHER is what makes the call throw.
    @Test("an absent tree throws rather than reporting a clean strip")
    func anAbsentTreeFails() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("macamp-absent-tree-\(UUID().uuidString)", isDirectory: true)

        #expect(throws: ToolExecutableFile.Failure.self) {
            try ToolExecutableFile.makeTreeRunnable(
                at: absent,
                executable: absent.appendingPathComponent("yt-dlp_macos")
            )
        }
    }

    // MARK: Fixtures

    struct TreeFixture {
        let root: URL
        let launcher: URL
        let nestedLibrary: URL
    }

    /// The PyInstaller onedir shape in miniature: a launcher plus an `_internal/`
    /// directory holding the Python shared library and one more `.dylib`.
    func makeTreeFixture() throws -> TreeFixture {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("macamp-tree-\(UUID().uuidString)", isDirectory: true)
        let internals = root.appendingPathComponent("_internal", isDirectory: true)
        try manager.createDirectory(at: internals, withIntermediateDirectories: true)
        let launcher = root.appendingPathComponent("yt-dlp_macos")
        let python = internals.appendingPathComponent("Python")
        let nested = internals.appendingPathComponent("libnested.dylib")
        for file in [launcher, python, nested] {
            try Data("stub".utf8).write(to: file)
        }
        return TreeFixture(root: root, launcher: launcher, nestedLibrary: nested)
    }
}

/// Writes a realistic Gatekeeper quarantine value, returning `setxattr`'s status.
func treeSetQuarantine(on url: URL) -> Int32 {
    let value = Array("0081;68c0a1b2;Test;".utf8)
    return url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return setxattr(path, ToolExecutableFile.quarantineAttribute, value, value.count, 0, 0)
    }
}

/// Whether `url` still carries the quarantine attribute.
func treeHasQuarantine(_ url: URL) -> Bool {
    url.withUnsafeFileSystemRepresentation { path -> Bool in
        guard let path else { return false }
        return getxattr(path, ToolExecutableFile.quarantineAttribute, nil, 0, 0, 0) >= 0
    }
}
