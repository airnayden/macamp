// DownloadDestinationTests — the shell-side decisions the download queue stands on.
//
// Three of these cannot be covered from `swift test`, which is why they live here: the
// destination resolver, the TCC write probe, and the scan-exclusion set are all
// `macOS/Sources` types the SwiftPM package cannot see.
//
// The probe is the load-bearing one. Its whole purpose is to answer the question
// `FileManager.isWritableFile(atPath:)` gets WRONG — that API reads the POSIX mode bits
// and reports `true` for a folder the app is not actually allowed to write to — so the
// only honest test is a directory that really refuses the write.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Download destination")
struct DownloadDestinationTests {
    @Test("the default destination is ~/Music/MacAMP Downloads")
    func defaultDestinationLivesInMusic() {
        let directory = DownloadDestinationLocation.defaultDirectory()

        #expect(directory.lastPathComponent == "MacAMP Downloads")
        #expect(directory.deletingLastPathComponent().lastPathComponent == "Music")
    }

    /// An empty stored path is the same "nothing configured" state as `nil`: a settings
    /// pane that clears its field must fall back to the default folder, not resolve the
    /// current working directory.
    @Test("a configured path wins, and an absent or empty one falls back to the default")
    func resolveHonoursTheConfiguredPath() {
        let configured = DownloadDestinationLocation.resolve(configuredPath: "/tmp/macamp-elsewhere")
        let fallback = DownloadDestinationLocation.defaultDirectory()

        #expect(configured.path == "/tmp/macamp-elsewhere")
        #expect(DownloadDestinationLocation.resolve(configuredPath: nil) == fallback)
        #expect(DownloadDestinationLocation.resolve(configuredPath: "") == fallback)
    }

    /// "Created on first use": the probe is the first use, and it leaves the folder
    /// behind but not its own probe file.
    @Test("the probe creates a missing destination and leaves nothing behind")
    func probeCreatesTheDirectoryAndCleansUpAfterItself() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macamp-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(DownloadDestinationProbe.isWritable(directory))

        #expect(FileManager.default.fileExists(atPath: directory.path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.isEmpty)
    }

    /// The failure path the whole seam exists for: a destination the app cannot write to
    /// answers `false`, so the queue reports `.destinationUnavailable` for that row
    /// BEFORE a byte is fetched and before an engine child is spawned.
    ///
    /// Mode `0o500` (r-x------) is a real refusal from the filesystem, which is the
    /// closest a test can get to a TCC denial without a privacy prompt. The permissions
    /// are restored before removal so the temp directory can actually be deleted.
    @Test("an unwritable destination answers false")
    func probeRefusesAnUnwritableDirectory() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("macamp-readonly-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? manager.removeItem(at: directory)
        }
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        #expect(!DownloadDestinationProbe.isWritable(directory))
    }

    /// The exclusion names the two APP-PRIVATE directories and NOTHING else.
    ///
    /// The destination's absence is asserted explicitly: excluding it would silently
    /// disable the whole feature — every download would import zero rows — and that is a
    /// failure with no error message anywhere, which is exactly the kind a test has to
    /// carry rather than a comment.
    @Test("the scan exclusion covers staging and tools, never the destination")
    func exclusionCoversOnlyThePrivateDirectories() {
        let excluded = DownloadPrivateDirectories.excluded

        #expect(excluded == [DownloadPrivateDirectories.staging, DownloadPrivateDirectories.tools])
        #expect(DownloadPrivateDirectories.staging.lastPathComponent == "Downloads-Staging")
        #expect(DownloadPrivateDirectories.tools.lastPathComponent == "Tools")
        #expect(!excluded.contains(DownloadDestinationLocation.defaultDirectory()))
    }
}
