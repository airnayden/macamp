// ToolUpdateInstaller — download, VERIFY, swap, validate, and roll back the engine.
//
// The whole yt-dlp self-update, expressed over the two seams todo 1 defined
// (``ToolReleaseFetching`` for bytes, ``ToolProcessRunning`` for `ditto`, `codesign`
// and `--version`) plus plain `FileManager`. Nothing here knows about `Process`,
// `URLSession`, or the app bundle, which is what lets `swift test` drive the entire
// flow — happy swap, bad-hash refusal, post-swap rollback — with scripted doubles and
// a real temporary directory.
//
// # The unit of installation is a DIRECTORY
//
// yt-dlp ships as a PyInstaller ONE-DIRECTORY tree: a `yt-dlp_macos` launcher plus a
// sibling `_internal/` holding the CPython runtime and ~100 shared libraries. The
// launcher resolves `_internal/Python` at startup, so the two are inseparable.
//
// This installer therefore fetches `yt-dlp_macos.zip`, not the bare `yt-dlp_macos`
// asset published beside it. Dropping that single file onto the launcher inside the
// tree WOULD run — a onefile binary ignores an `_internal/` sibling — while silently
// reinstating the ~12 s per-exec unpack the one-directory layout exists to remove,
// permanently, because the seed's older mtime then keeps the bad binary across every
// subsequent launch. There is no error anywhere in that failure, which is why the
// archive name is a parameter with exactly one correct value rather than a default.
//
// # The ordering that matters
// 1. Fetch the `SHA2-256SUMS` manifest and the ARCHIVE.
// 2. Hash the ARCHIVE and compare. **Nothing is written to disk before this passes.**
//    A mismatch throws with the installed engine untouched — not "downloaded, then
//    discovered to be wrong", and never "extracted, then discovered to be wrong".
// 3. Expand into a hidden sibling DIRECTORY of the target, assert the expansion
//    actually produced a launcher and a non-empty `_internal/`, and make the whole
//    tree runnable (mode + a RECURSIVE quarantine strip).
// 4. Rename the outgoing tree to `<name>.previous` BEFORE the swap, so a rollback has
//    somewhere to roll back to.
// 5. Validate the swapped tree before declaring success: `codesign -dv` on the
//    launcher, ad-hoc re-sign if it is unsigned, then actually RUN `--version`. Apple
//    Silicon refuses to execute a Mach-O with no signature at all, so a structurally
//    perfect install of an unsigned launcher is still a broken engine — and running it
//    is also what proves the extracted payload is intact.
// 6. Any failure after the swap restores `.previous` and reports ``DownloadError/updateFailed(detail:)``.
//
// Every spawn — `ditto`, both `codesign` calls, `--version` — goes through
// ``ToolProcessRunning``; this file must NEVER construct a process itself. Note that
// `codesign -dv` prints its report to STDERR, which is why ``ToolRunResult`` carries
// both streams rather than stdout alone.
//
// The filesystem mechanics (stage, expand, swap, roll back) live in
// ToolUpdateInstaller+Tree.swift; permission and quarantine hygiene in
// ToolExecutableFile.swift, which is where the `Darwin` xattr calls moved with it.
//
// This file imports Foundation and CryptoKit, and MUST NOT import AppKit/UIKit,
// Process, or URLSession (PlayerCore portability invariant + the downloader boundary gate).
import CryptoKit
import Foundation

/// Everything one spawned tool produced, collected.
///
/// Both streams are kept because `codesign -dv` reports to STDERR while yt-dlp's
/// `--version` reports to STDOUT — a result type that carried only one of them would
/// silently discard half of this file's diagnostics.
public struct ToolRunResult: Sendable, Equatable {
    /// Whole lines from standard output, in order.
    public let standardOutput: [String]
    /// Whole lines from standard error, in order.
    public let standardError: [String]
    /// How the tool ended.
    public let termination: ProcessTermination

    public init(standardOutput: [String], standardError: [String], termination: ProcessTermination) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.termination = termination
    }

    /// The first non-empty stdout line — a version string, when the tool printed one.
    public var firstOutputLine: String? {
        standardOutput.lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// The last non-empty stderr line — the most specific diagnostic a tool emitted.
    public var lastErrorLine: String? {
        standardError.lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    /// Runs `tool` through `runner` and collects everything it produced.
    ///
    /// The single place the ``ToolProcessRunning`` stream is drained, shared by the
    /// installer's `codesign` / `--version` calls and by the shell's tool manager —
    /// two drains would eventually disagree about what a missing termination means.
    ///
    /// - Throws: `CancellationError` when the stream finishes WITHOUT a termination
    ///   event, which is exactly how a killed child ends (todo 1's contract). "Finished
    ///   with no `ProcessTermination`" must never be read as success.
    public static func collecting(
        _ tool: URL,
        arguments: [String],
        through runner: any ToolProcessRunning
    ) async throws -> ToolRunResult {
        var standardOutput: [String] = []
        var standardError: [String] = []
        var termination: ProcessTermination?
        for try await event in try await runner.spawn(tool: tool, arguments: arguments) {
            switch event {
            case let .stdout(line): standardOutput.append(line)
            case let .stderr(line): standardError.append(line)
            case let .terminated(value): termination = value
            }
        }
        guard let termination else { throw CancellationError() }
        return ToolRunResult(
            standardOutput: standardOutput,
            standardError: standardError,
            termination: termination
        )
    }
}

/// Installs a checksum-verified engine update into a directory, with rollback.
public struct ToolUpdateInstaller: Sendable {
    /// The system code-signing tool. An absolute path because the child's `PATH` is
    /// sanitized and because this must resolve to Apple's binary, not a shadowed one.
    public static let codesignURL = URL(fileURLWithPath: "/usr/bin/codesign")

    /// The system archive expander, for the same reason and with the same caveat.
    ///
    /// `ditto` rather than `unzip` because it is Apple's own tool, preserves POSIX
    /// modes out of the archive, and refuses entries whose paths escape the
    /// destination — a property worth having on a path that expands downloaded bytes.
    public static let extractorURL = URL(fileURLWithPath: "/usr/bin/ditto")

    /// The PyInstaller payload directory that must sit beside the launcher.
    public static let payloadDirectoryName = "_internal"

    let releaseFetcher: any ToolReleaseFetching
    let processRunner: any ToolProcessRunning

    /// - Parameters:
    ///   - releaseFetcher: Supplies the checksum manifest and the asset bytes.
    ///   - processRunner: Runs `codesign` and the freshly installed engine.
    public init(releaseFetcher: any ToolReleaseFetching, processRunner: any ToolProcessRunning) {
        self.releaseFetcher = releaseFetcher
        self.processRunner = processRunner
    }

    /// Where the outgoing tree is kept so a failed update can be undone.
    ///
    /// A sibling DIRECTORY (`yt-dlp.previous` beside `yt-dlp`), not a file — the whole
    /// engine moves aside, because the launcher and its payload are only valid together.
    public static func previousURL(for treeURL: URL) -> URL {
        treeURL.appendingPathExtension("previous")
    }

    /// Downloads `release`'s archive, verifies it, installs the expanded tree at
    /// `treeURL`, and proves the result actually runs.
    ///
    /// - Parameters:
    ///   - release: The published release to install.
    ///   - archiveName: The ARCHIVE's file name in the release's checksum manifest —
    ///     `yt-dlp_macos.zip`, never the bare `yt-dlp_macos` published beside it. See
    ///     this file's header for why the wrong one is a silent, permanent regression.
    ///   - executableName: The launcher's name inside the archive and inside the tree.
    ///   - treeURL: Where the engine tree lives. Its PARENT must already exist; the
    ///     tree itself may be absent (a first install).
    /// - Returns: The version the newly installed launcher reports, falling back to the
    ///   release tag when it printed nothing.
    /// - Throws: ``DownloadError/updateFailed(detail:)`` at every failure point. The
    ///   previously installed tree is left in place (or restored) in all of them.
    @discardableResult
    public func installTree(
        _ release: ToolRelease,
        archiveName: String,
        executableName: String,
        at treeURL: URL
    ) async throws -> String {
        let expected = try await expectedDigest(for: archiveName, in: release)
        let archive = try await releaseFetcher.fetchData(from: release.assetURL)
        try verify(archive, matches: expected)
        let staged = try await stageTree(archive, beside: treeURL, executableName: executableName)
        let previous = try backUpTree(treeURL)
        do {
            try swapTree(staged, onto: treeURL)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            restoreTree(previous, at: treeURL)
            throw error
        }
        let executable = treeURL.appendingPathComponent(executableName)
        do {
            try await validateSignature(at: executable)
            return try await installedVersion(at: executable, fallback: release.tag)
        } catch {
            restoreTree(previous, at: treeURL)
            throw error
        }
    }
}

// MARK: - Fetch and verify (nothing is written during this phase)

extension ToolUpdateInstaller {
    /// The digest `assetName` is published under, or a refusal.
    ///
    /// A release whose manifest does not cover the asset is not installable: there is
    /// nothing to check the bytes against, and an unverifiable binary is never swapped in.
    func expectedDigest(for assetName: String, in release: ToolRelease) async throws -> String {
        let manifest = try await releaseFetcher.fetchData(from: release.checksumURL)
        // Failable on purpose: bytes that are not UTF-8 are not a manifest, and a
        // lossy decode would turn that into a confusing "asset not listed" instead.
        guard let text = String(bytes: manifest, encoding: .utf8) else {
            throw DownloadError.updateFailed(detail: "the checksum manifest was not readable text")
        }
        guard let digest = ToolUpdatePlanner.checksum(forAsset: assetName, in: text) else {
            throw DownloadError.updateFailed(detail: "no SHA-256 published for \(assetName)")
        }
        return digest
    }

    /// Throws unless `asset` hashes to `expected`.
    ///
    /// This runs BEFORE anything touches the filesystem, which is the whole point:
    /// a tampered or truncated download must not be able to reach the installed path
    /// even transiently.
    func verify(_ asset: Data, matches expected: String) throws {
        let actual = SHA256.hash(data: asset).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw DownloadError.updateFailed(detail: "checksum mismatch: expected \(expected), got \(actual)")
        }
    }
}

// MARK: - Post-swap validation (every spawn goes through the seam)

extension ToolUpdateInstaller {
    /// Ensures the installed binary carries a signature, ad-hoc signing it if it does not.
    ///
    /// Apple Silicon will not execute an unsigned Mach-O at all. yt-dlp's PyInstaller
    /// build is ad-hoc signed upstream (measured, not assumed), so the re-sign branch
    /// is a safety net rather than the normal path — but a release that ever ships
    /// unsigned would otherwise install cleanly and then die with a code-signing kill.
    func validateSignature(at executableURL: URL) async throws {
        let inspection = try await run(Self.codesignURL, arguments: ["-dv", executableURL.path])
        guard !inspection.termination.isSuccess else { return }
        let signing = try await run(
            Self.codesignURL,
            arguments: ["-s", "-", "--force", executableURL.path]
        )
        guard signing.termination.isSuccess else {
            throw DownloadError.updateFailed(
                detail: "ad-hoc signing failed: \(signing.lastErrorLine ?? inspection.lastErrorLine ?? "")"
            )
        }
    }

    /// Runs the freshly installed engine and returns what it calls itself.
    ///
    /// This is the acceptance test for the whole update: a binary that cannot answer
    /// `--version` is not an engine, however well the bytes verified.
    func installedVersion(at executableURL: URL, fallback: String) async throws -> String {
        let result = try await run(executableURL, arguments: ["--version"])
        guard result.termination.isSuccess else {
            throw DownloadError.updateFailed(
                detail: "the installed engine failed to run: \(result.lastErrorLine ?? "status \(result.termination.status)")"
            )
        }
        return result.firstOutputLine ?? fallback
    }

    func run(_ tool: URL, arguments: [String]) async throws -> ToolRunResult {
        try await ToolRunResult.collecting(tool, arguments: arguments, through: processRunner)
    }
}
