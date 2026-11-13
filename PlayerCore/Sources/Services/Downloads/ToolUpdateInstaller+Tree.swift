// ToolUpdateInstaller+Tree — the filesystem half of the engine self-update: stage,
// expand, prove intact, swap, and roll back a whole DIRECTORY.
//
// Split from ToolUpdateInstaller.swift for the 400-line ceiling. The extension is
// `internal` rather than `private` only because Swift scopes `private` to a single
// file; nothing here is called from outside the two installer files.
//
// ── WHY EVERY STEP IS A RENAME, NOT A COPY ───────────────────────────────────
//
// The tree is ~124 MB across 134 files, so a copy is both slow and observable
// half-finished — and a half-populated engine tree is a launcher that starts and then
// dies inside. Staging in the target's OWN parent directory keeps every transition a
// same-volume rename, which the kernel does atomically.
//
// ── WHY THE BACKUP IS BUILT BY HAND ──────────────────────────────────────────
//
// `FileManager.replaceItemAt(_:withItemAt:backupItemName:options:)` looks like exactly
// the right API and is NOT: for a DIRECTORY it performs the swap and then silently
// produces no backup at all (measured — the named `.previous` simply never appears,
// and the call still returns success). A rollback built on it would have nothing to
// roll back to, and would discover that only at the moment it was needed.
//
// Foundation only. No AppKit/UIKit, no Process, no URLSession — every spawn goes
// through ``ToolProcessRunning``.
import Foundation

extension ToolUpdateInstaller {
    /// Expands `archive` into a hidden sibling of `treeURL` and makes it runnable.
    ///
    /// The archive is written beside the tree rather than into a temporary directory so
    /// the expansion lands on the same volume as its destination, which is what makes
    /// the swap that follows a rename. It is removed again either way.
    func stageTree(_ archive: Data, beside treeURL: URL, executableName: String) async throws -> URL {
        let parent = treeURL.deletingLastPathComponent()
        let token = UUID().uuidString
        let archiveURL = parent.appendingPathComponent(".macamp-tool-\(token).zip")
        let staged = parent.appendingPathComponent(".macamp-tool-\(token)", isDirectory: true)
        do {
            try archive.write(to: archiveURL, options: .atomic)
        } catch {
            throw DownloadError.updateFailed(detail: "could not stage the download: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        do {
            try await expand(archiveURL, into: staged)
            let executable = staged.appendingPathComponent(executableName)
            try assertTreeIsIntact(at: staged, executable: executable)
            try ToolExecutableFile.makeTreeRunnable(at: staged, executable: executable)
            stampInstallTime(on: executable)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error as? DownloadError
                ?? DownloadError.updateFailed(detail: "could not stage the engine tree: \(error)")
        }
        return staged
    }

    /// Rewrites `executable`'s modification date to NOW, before the swap.
    ///
    /// This is what keeps a self-update installed. `DownloadToolManager.shouldCopy`
    /// decides on every launch whether the bundle's seed replaces what is installed,
    /// and it answers "is the installed launcher OLDER than the seed?". That question
    /// is only meaningful while an installed launcher's date is the date it was
    /// INSTALLED — and after the onefile→onedir migration, nothing on this path made
    /// it so:
    ///
    /// - `ditto -x -k` restores each entry's date STORED IN THE ARCHIVE, not the time
    ///   of extraction (measured: a file stamped 2026-01-15 09:00, zipped and
    ///   re-extracted eight months later, comes back at 2026-01-15 09:00). The old
    ///   flow wrote the binary with `Data.write(to:options:.atomic)`, which stamps
    ///   "now" — so the invariant used to be structurally true and silently stopped
    ///   being so.
    /// - `codesign` rewrites the Mach-O, so the SEED launcher inside a signed release
    ///   carries the APP's signing date, and `FileManager.copyItem` preserves it out
    ///   to the tools directory.
    ///
    /// An app is always signed after the yt-dlp version it pins, so without this line
    /// a signed release compares "yt-dlp's release date" against "the app's signing
    /// date", concludes the seed is newer, and reverts every successful self-update on
    /// the next launch — offering the same update for ever. Unsigned dev builds cannot
    /// reproduce it, which is why 212 green tests and a working manual update did not.
    ///
    /// Stamping is preferred over teaching `shouldCopy` to compare VERSIONS instead of
    /// dates: reading a version means spawning the launcher, and `shouldCopy` runs on
    /// the launch path, where the whole point of the onedir tree is not paying that.
    ///
    /// Failures are swallowed. This runs BEFORE the swap, so it adds no failure window,
    /// and refusing a verified, expanded, intact tree because a timestamp would not
    /// write is the worse of the two mistakes — the fallback is the reverted-on-relaunch
    /// behaviour that shipped, not a broken engine.
    func stampInstallTime(on executable: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: executable.path
        )
    }

    /// Expands `archive` into `destination` through the process seam.
    func expand(_ archive: URL, into destination: URL) async throws {
        let result = try await ToolRunResult.collecting(
            Self.extractorURL,
            arguments: ["-x", "-k", archive.path, destination.path],
            through: processRunner
        )
        guard result.termination.isSuccess else {
            throw DownloadError.updateFailed(
                detail: "could not expand the engine archive: "
                    + (result.lastErrorLine ?? "status \(result.termination.status)")
            )
        }
    }

    /// Throws unless `root` holds the launcher AND a non-empty payload directory.
    ///
    /// This is the whole reason a one-directory update cannot be a file swap. A
    /// launcher without its `_internal/` sibling passes every existence check, signs
    /// cleanly, and then exits with "Failed to load Python shared library" — a failure
    /// that would otherwise be discovered by the first person to try a download, on a
    /// tree that has already replaced a working one.
    func assertTreeIsIntact(at root: URL, executable: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: executable.path) else {
            throw DownloadError.updateFailed(
                detail: "the engine archive contained no \(executable.lastPathComponent)"
            )
        }
        let payload = root.appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: payload.path, isDirectory: &isDirectory)
        let entries = (try? manager.contentsOfDirectory(atPath: payload.path)) ?? []
        guard exists, isDirectory.boolValue, !entries.isEmpty else {
            throw DownloadError.updateFailed(
                detail: "the engine archive contained no \(Self.payloadDirectoryName)/ payload"
            )
        }
    }

    /// Renames the installed tree aside as `<name>.previous`.
    ///
    /// Returns `nil` when there was nothing installed yet — a first install has no
    /// predecessor, and that is a normal state, not a failure.
    func backUpTree(_ treeURL: URL) throws -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: treeURL.path) else { return nil }
        let previous = Self.previousURL(for: treeURL)
        try? manager.removeItem(at: previous)
        do {
            try manager.moveItem(at: treeURL, to: previous)
        } catch {
            throw DownloadError.updateFailed(detail: "could not keep a rollback copy: \(error)")
        }
        return previous
    }

    /// Moves the staged tree into place.
    ///
    /// ``backUpTree(_:)`` has already vacated the destination, so this is an
    /// unconditional rename. The gap between the two is the only window in which no
    /// engine exists at the real path, and it is self-healing: provisioning re-copies
    /// the bundle seed whenever the installed tree is absent.
    func swapTree(_ staged: URL, onto treeURL: URL) throws {
        do {
            try FileManager.default.moveItem(at: staged, to: treeURL)
        } catch {
            throw DownloadError.updateFailed(detail: "could not install the engine: \(error)")
        }
    }

    /// Puts `previous` back, or removes the tree entirely when there was no predecessor.
    ///
    /// Unlike the single-file flow this replaced, the rollback does NOT retain a copy:
    /// once the restored tree is live, `<name>.previous` would be 124 MB duplicating
    /// bytes that are already there, and the bundle seed remains an unconditional
    /// fallback. Failures here are swallowed on purpose — the caller is already
    /// throwing the error that actually explains what went wrong.
    func restoreTree(_ previous: URL?, at treeURL: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: treeURL)
        guard let previous, manager.fileExists(atPath: previous.path) else { return }
        try? manager.moveItem(at: previous, to: treeURL)
    }
}
