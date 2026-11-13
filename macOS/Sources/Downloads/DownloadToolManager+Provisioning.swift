// DownloadToolManager+Provisioning — copying the download tools out of the read-only
// app bundle into `~/Library/Application Support/MacAMP/Tools/`.
//
// Split off from DownloadToolManager.swift when yt-dlp became a PyInstaller
// one-directory tree: the tree needs its own resolve / stage / swap / hygiene path
// beside the single-file one, which put that file over the 400-line ceiling.
//
// The extension is `internal` rather than `private` only because Swift scopes
// `private` to a single file; nothing here is called from outside the two
// DownloadToolManager files.
//
// Why the bundle is a SOURCE and never a run location, and which Foundation lookup
// owns which bundle folder, are documented in DownloadToolManager.swift's header.
import Foundation
import Services

extension DownloadToolManager {
    /// The bundled yt-dlp tree, or `nil` when this build shipped without one.
    ///
    /// `Bundle.url(forResource:withExtension:)` is the Foundation API for
    /// `Contents/Resources`, where a Tuist `.folderReference` lands — the direct
    /// counterpart of `url(forAuxiliaryExecutable:)` for `Contents/MacOS`. This is
    /// the ONLY expression in the app that names the tree's location in the bundle.
    var seedTreeURL: URL? {
        bundle.url(forResource: Self.ytDlpTreeName, withExtension: nil)
    }

    /// Resolves a tool's URL, performing the one-time copy-out first if needed.
    func preparedURL(of name: String) async throws -> URL {
        if !didPrepare { try await prepare() }
        return toolsDirectory.appendingPathComponent(name)
    }

    /// Ensures the yt-dlp tree exists in the tools directory and is runnable.
    ///
    /// Staleness is decided on the LAUNCHER's timestamp rather than the directory's:
    /// a directory's mtime changes when anything inside it is touched, which would
    /// make "absent or older" answer about the last file written instead of about
    /// the release. The launcher is the file a new release actually replaces.
    func provisionYtDlpTree() throws {
        let installedTree = ytDlpTreeURL
        let installedLauncher = installedTree.appendingPathComponent(Self.ytDlpExecutableName)
        if let seedTree = seedTreeURL,
           shouldCopy(seedTree.appendingPathComponent(Self.ytDlpExecutableName), over: installedLauncher)
        {
            try copySeedTree(seedTree, to: installedTree)
        }
        guard FileManager.default.fileExists(atPath: installedLauncher.path) else {
            throw DownloadError.toolMissing
        }
        do {
            try ToolExecutableFile.makeTreeRunnable(at: installedTree, executable: installedLauncher)
        } catch {
            throw DownloadError.toolMissing
        }
        removeLegacyOnefileEngine()
    }

    /// Deletes the pre-onedir engine an earlier build installed LOOSE in the tools
    /// directory.
    ///
    /// Without this, upgrading leaves a dead 37 MB binary beside the tree on every
    /// existing install — nothing reads it once ``ytDlpURL`` points inside the tree, so
    /// it is pure waste and a decoy for anyone (or any script) that goes looking for
    /// "the engine" by filename.
    ///
    /// Runs only AFTER the tree is proven present and runnable, so a build that failed
    /// to provision never destroys the engine it still has. It cannot collide with the
    /// self-update's rollback copy either: that is written inside the tree, not here.
    func removeLegacyOnefileEngine() {
        let legacy = toolsDirectory.appendingPathComponent(Self.ytDlpExecutableName)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        try? FileManager.default.removeItem(at: legacy)
    }

    /// Ensures `name` exists in the tools directory and is runnable.
    func provision(_ name: String) throws {
        let installed = toolsDirectory.appendingPathComponent(name)
        if let seed = bundle.url(forAuxiliaryExecutable: name), shouldCopy(seed, over: installed) {
            try copySeed(seed, to: installed)
        }
        guard FileManager.default.fileExists(atPath: installed.path) else {
            throw DownloadError.toolMissing
        }
        do {
            try ToolExecutableFile.makeRunnable(at: installed)
        } catch {
            throw DownloadError.toolMissing
        }
    }

    /// Whether the bundle's seed should replace what is installed.
    ///
    /// "Absent or older": a self-updated yt-dlp is NEWER than the seed it came from, so
    /// it survives every launch — while an app update, whose seed is newer again,
    /// correctly takes over. Two files whose dates cannot be read are left alone, since
    /// clobbering a working engine on the strength of missing metadata is the worse of
    /// the two mistakes.
    ///
    /// ── WHAT MAKES "A SELF-UPDATE IS NEWER" TRUE ─────────────────────────────
    ///
    /// Nothing about it is automatic, and it was briefly FALSE in shipped signed
    /// releases. Three measured facts decide these two dates:
    ///
    /// - The SEED's date is the app's CODE-SIGNING time. `codesign` rewrites the
    ///   Mach-O it seals, and `FileManager.copyItem` then preserves that date out to
    ///   the tools directory — so on a signed release the seed is stamped days or
    ///   weeks AFTER the yt-dlp version it carries.
    /// - The INSTALL's date would otherwise be the archive's STORED date:
    ///   `ditto -x -k` restores each entry's date out of the zip rather than stamping
    ///   the extraction — so a self-update would arrive carrying yt-dlp's own release
    ///   date, older than the seed beside it, and be reverted on the next launch.
    /// - It is not, because ``ToolUpdateInstaller`` stamps the staged launcher with
    ///   the install time before the swap (`stampInstallTime(on:)`), which is the
    ///   single line this comparison rests on. The pre-onedir flow got the same
    ///   property for free from `Data.write(to:options:.atomic)`.
    ///
    /// Anything that reintroduces an archive-preserved or copy-preserved date on the
    /// installed launcher silently resurrects "every engine update is undone at the
    /// next launch" — a failure with no error anywhere in it, invisible to unsigned
    /// dev builds because those never stamp the seed with a signing time at all.
    func shouldCopy(_ seed: URL, over installed: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: installed.path) else { return true }
        guard let seedDate = modificationDate(of: seed),
              let installedDate = modificationDate(of: installed)
        else {
            return false
        }
        return installedDate < seedDate
    }

    func modificationDate(of url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    /// Copies the seed in through a hidden sibling and an atomic replace.
    ///
    /// Staging in the same directory means the swap is a rename, so a crash partway
    /// through can leave a stray temp file but never a truncated engine at the real path.
    func copySeed(_ seed: URL, to installed: URL) throws {
        let manager = FileManager.default
        let staged = toolsDirectory.appendingPathComponent(".macamp-seed-\(UUID().uuidString)")
        do {
            try manager.copyItem(at: seed, to: staged)
            try ToolExecutableFile.makeRunnable(at: staged)
            if manager.fileExists(atPath: installed.path) {
                _ = try manager.replaceItemAt(installed, withItemAt: staged)
            } else {
                try manager.moveItem(at: staged, to: installed)
            }
        } catch {
            try? manager.removeItem(at: staged)
            throw DownloadError.toolMissing
        }
    }

    /// Copies the seed TREE in through a hidden sibling and an atomic replace.
    ///
    /// Same shape as ``copySeed(_:to:)`` and for a sharper reason: this moves 124 MB
    /// across 134 files, so writing it directly at the real path would leave a
    /// half-populated tree on any interruption — which the launcher would happily
    /// start and then fail inside. Staging in the same directory keeps the swap a
    /// rename, so the tree is either the old one or the new one.
    ///
    /// Permissions and quarantine are asserted by the caller AFTER the swap rather
    /// than on the staged copy: ``provisionYtDlpTree()`` re-runs them on every launch,
    /// which is what also covers a tree an older build left quarantined.
    func copySeedTree(_ seed: URL, to installed: URL) throws {
        let manager = FileManager.default
        let staged = toolsDirectory
            .appendingPathComponent(".macamp-seed-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.copyItem(at: seed, to: staged)
            if manager.fileExists(atPath: installed.path) {
                _ = try manager.replaceItemAt(installed, withItemAt: staged)
            } else {
                try manager.moveItem(at: staged, to: installed)
            }
        } catch {
            try? manager.removeItem(at: staged)
            throw DownloadError.toolMissing
        }
    }
}
