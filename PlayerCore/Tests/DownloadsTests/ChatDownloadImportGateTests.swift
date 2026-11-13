// ChatDownloadImportGate coverage — the import policy, case by case.
//
// Every path in the table below is spelled out as a literal rather than derived from
// its own root, for the same double-entry reason `YtDlpCommandBuilderTests` restates
// the quality table: a fixture assembled by appending to the root it is checked
// against would keep agreeing with whatever the prefix rule became — including a
// plain `String.hasPrefix`, which is exactly the bug `siblingPrefixIsNotUnderRoot`
// exists to lock out.
//
// Two cases cannot be table-driven, because they need the filesystem's own answer
// rather than a literal:
//
//   * the `/private` symlink round trip — macOS resolves `/var` → `/private/var`, so a
//     root and a file naming the SAME directory can disagree textually. The test
//     creates a real directory under the temporary directory (which lives under
//     `/var/folders/…`) so both spellings are genuine rather than assumed.
//   * the relative-URL case — `URL(fileURLWithPath:)` resolves a relative path against
//     the current working directory, which no literal can predict.
import Foundation
import Services
import Testing

@Suite("Chat download import gate")
struct ChatDownloadImportGateTests {
    // MARK: - Table

    /// One row of the policy table: the three inputs and the expected verdict.
    struct GateCase: CustomTestStringConvertible {
        let label: String
        let autoImportEnabled: Bool
        let filePath: String
        let rootPaths: [String]
        let expected: Bool

        var testDescription: String {
            label
        }
    }

    static let policyCases: [GateCase] = [
        GateCase(
            label: "auto-import on short-circuits with no roots at all",
            autoImportEnabled: true,
            filePath: "/Users/t/Downloads/a.m4a",
            rootPaths: [],
            expected: true
        ),
        GateCase(
            label: "auto-import on short-circuits even when no root would match",
            autoImportEnabled: true,
            filePath: "/Users/t/Downloads/a.m4a",
            rootPaths: ["/Users/t/Music"],
            expected: true
        ),
        GateCase(
            label: "a file directly in a root is under it",
            autoImportEnabled: false,
            filePath: "/Users/t/Music/a.m4a",
            rootPaths: ["/Users/t/Music"],
            expected: true
        ),
        GateCase(
            label: "a file in a nested subfolder of a root is under it",
            autoImportEnabled: false,
            filePath: "/Users/t/Music/Albums/2024/a.m4a",
            rootPaths: ["/Users/t/Music"],
            expected: true
        ),
        GateCase(
            label: "a sibling folder whose name merely begins with the root's is NOT under it",
            autoImportEnabled: false,
            filePath: "/Users/t/MusicLibrary/a.m4a",
            rootPaths: ["/Users/t/Music"],
            expected: false
        ),
        GateCase(
            label: "no roots at all and auto-import off refuses everything",
            autoImportEnabled: false,
            filePath: "/Users/t/Music/a.m4a",
            rootPaths: [],
            expected: false
        ),
        GateCase(
            label: "a file outside every root is refused",
            autoImportEnabled: false,
            filePath: "/Users/t/Downloads/a.m4a",
            rootPaths: ["/Users/t/Music", "/Users/t/Podcasts"],
            expected: false
        ),
        GateCase(
            label: "the second of several roots is enough",
            autoImportEnabled: false,
            filePath: "/Users/t/Podcasts/a.m4a",
            rootPaths: ["/Users/t/Music", "/Users/t/Podcasts"],
            expected: true
        ),
        GateCase(
            label: "a trailing slash on the root changes nothing",
            autoImportEnabled: false,
            filePath: "/Users/t/Music/a.m4a",
            rootPaths: ["/Users/t/Music/"],
            expected: true
        ),
        GateCase(
            label: "a `..` segment in the root is standardized away",
            autoImportEnabled: false,
            filePath: "/Users/t/Music/a.m4a",
            rootPaths: ["/Users/t/Podcasts/../Music"],
            expected: true
        ),
        GateCase(
            label: "a URL naming the root directory itself counts as under it",
            autoImportEnabled: false,
            filePath: "/Users/t/Music",
            rootPaths: ["/Users/t/Music"],
            expected: true
        ),
        GateCase(
            label: "a root deeper than the file cannot contain it",
            autoImportEnabled: false,
            filePath: "/Users/t/a.m4a",
            rootPaths: ["/Users/t/Music/Albums"],
            expected: false
        ),
        // Documented, deliberately NOT special-cased: a root of "/" legitimately
        // contains every absolute path, so the gate says yes. Someone who adds "/"
        // as a library root has asked for exactly that.
        GateCase(
            label: "a root of `/` matches every absolute path",
            autoImportEnabled: false,
            filePath: "/Users/t/Downloads/a.m4a",
            rootPaths: ["/"],
            expected: true
        ),
        // Documented behaviour, not an endorsement: components are compared for exact
        // equality, and roots are stored verbatim as the listener picked them
        // (`GRDBLibraryRootsStore.load`), so a case variant is a different root. If
        // case-insensitive roots are ever wanted, this row is the one to revisit.
        GateCase(
            label: "component comparison is exact, so a case-variant root does not match",
            autoImportEnabled: false,
            filePath: "/Users/t/music/a.m4a",
            rootPaths: ["/Users/t/Music"],
            expected: false
        ),
    ]

    static func verdict(for testCase: GateCase) -> Bool {
        ChatDownloadImportGate.isEligible(
            autoImportEnabled: testCase.autoImportEnabled,
            fileURL: URL(fileURLWithPath: testCase.filePath),
            libraryRoots: testCase.rootPaths.map { URL(fileURLWithPath: $0) }
        )
    }

    @Test("the policy table", arguments: policyCases)
    func policyTable(testCase: GateCase) {
        #expect(Self.verdict(for: testCase) == testCase.expected)
    }

    // MARK: - The component-awareness lock

    /// The plan's named failure case, restated outside the table so it cannot be lost
    /// in a row reshuffle: `/Users/t/Music` must not swallow `/Users/t/MusicLibrary`.
    /// A `String.hasPrefix` implementation passes every other row here and fails this
    /// one, which is the whole point of writing it twice.
    @Test("a sibling folder sharing the root's name prefix is not under the root")
    func siblingPrefixIsNotUnderRoot() {
        let eligible = ChatDownloadImportGate.isEligible(
            autoImportEnabled: false,
            fileURL: URL(fileURLWithPath: "/Users/t/MusicLibrary/a.m4a"),
            libraryRoots: [URL(fileURLWithPath: "/Users/t/Music")]
        )
        #expect(eligible == false)
    }

    // MARK: - Real-filesystem cases

    /// `/var` is a symlink to `/private/var` on macOS, so the same directory has two
    /// real spellings. The roots store holds whichever one the listener's picker
    /// produced and the download callback reports whichever one the engine produced —
    /// they are not required to agree, so the gate resolves both sides before comparing.
    ///
    /// Measured direction (2026-09-16, macOS 26 / Swift 6): `resolvingSymlinksInPath()`
    /// normalizes toward the SHORT form — it strips `/private` rather than adding it,
    /// so both spellings converge on `/var/…`. The test therefore builds the long
    /// spelling explicitly and proves it names an existing directory before using it,
    /// rather than assuming resolution produces it.
    @Test("a /private symlink spelling matches its /var spelling in both directions")
    func privateSymlinkSpellingsMatchBothWays() throws {
        let fileManager = FileManager.default
        let shortRoot = fileManager.temporaryDirectory
            .appendingPathComponent("macamp-import-gate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: shortRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: shortRoot) }

        let longRoot = URL(fileURLWithPath: "/private" + shortRoot.path, isDirectory: true)
        // Without these the case would be vacuous: the two spellings must really differ
        // AND must really name the same existing directory.
        #expect(longRoot.path != shortRoot.path)
        #expect(fileManager.fileExists(atPath: longRoot.path))

        let shortFile = shortRoot.appendingPathComponent("a.m4a")
        let longFile = longRoot.appendingPathComponent("a.m4a")
        try Data().write(to: shortFile)
        #expect(fileManager.fileExists(atPath: longFile.path))

        #expect(ChatDownloadImportGate.isEligible(
            autoImportEnabled: false,
            fileURL: shortFile,
            libraryRoots: [longRoot]
        ))
        #expect(ChatDownloadImportGate.isEligible(
            autoImportEnabled: false,
            fileURL: longFile,
            libraryRoots: [shortRoot]
        ))

        // Cleanup receipt: the deferred remove above is belt-and-braces; this is the
        // assertion that the temporary directory really left no residue behind.
        try fileManager.removeItem(at: shortRoot)
        #expect(fileManager.fileExists(atPath: shortRoot.path) == false)
    }

    /// `URL(fileURLWithPath:)` resolves a relative path against the process's working
    /// directory, so a relative-looking string is never actually relative by the time
    /// the gate sees it. Callers always hand this gate absolute file URLs (the engine's
    /// `after_move` path and the roots store's `URL(fileURLWithPath:)` rows both are);
    /// this pins what would happen if one did not, in both directions.
    @Test("a relative-looking file URL standardizes against the working directory")
    func relativeFileURLStandardizesAgainstTheWorkingDirectory() {
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let relative = URL(fileURLWithPath: "Music/a.m4a")

        #expect(ChatDownloadImportGate.isEligible(
            autoImportEnabled: false,
            fileURL: relative,
            libraryRoots: [workingDirectory.appendingPathComponent("Music", isDirectory: true)]
        ))
        #expect(ChatDownloadImportGate.isEligible(
            autoImportEnabled: false,
            fileURL: relative,
            libraryRoots: [URL(fileURLWithPath: "/Users/t/Music")]
        ) == false)
    }
}
