// DropImport — the testable seam behind the macOS drag-and-drop folder/file import.
//
// The macOS shell accepts dropped folders and audio files on the library detail
// and the main window. This file holds the PORTABLE, unit-testable core of that
// flow so it can be exercised under `swift test` (the macOS app target has no test
// target). The view layer stays thin: it builds a ``DropImporter``, classifies the
// dropped URLs, then runs the plan on a `Task`.
//
//   * `plan(for:existingRoots:)` — pure classification: directory ⇒ a new library
//     root (deduplicated by standardized path), audio file ⇒ a loose one-shot
//     import, everything else ⇒ rejected (gracefully ignored). No I/O beyond the
//     injectable `isDirectory` probe.
//   * `run(_:addRoot:)` — executes a plan: registers each new folder via the
//     caller-supplied `addRoot` side effect, scans the folders, and one-shot
//     imports the loose audio files via the ``LibraryScanning`` pipeline.
//
// Imports only Foundation (PlayerCore portability invariant — no AppKit/UIKit).
import Foundation

// MARK: - DropImportPlan

/// How a set of dropped URLs was classified, before any scan runs.
public struct DropImportPlan: Sendable, Equatable {
    /// Directories to register as new library roots (standardized, deduplicated
    /// against the roots already present).
    public var roots: [URL]
    /// Individual audio files to one-shot import (standardized).
    public var looseFiles: [URL]
    /// URLs ignored: non-audio files, or folders already registered as a root.
    public var rejected: [URL]

    public init(roots: [URL] = [], looseFiles: [URL] = [], rejected: [URL] = []) {
        self.roots = roots
        self.looseFiles = looseFiles
        self.rejected = rejected
    }

    /// Whether the drop yielded anything to import (the view rejects the drop —
    /// returns `false` from `.dropDestination` — when this is `true`).
    public var isEmpty: Bool {
        roots.isEmpty && looseFiles.isEmpty
    }
}

// MARK: - DropImporter

/// Classifies and executes a drag-and-drop import. `Sendable` so a view can build
/// one per drop; `run(_:addRoot:)` is `@MainActor` because its `addRoot` side
/// effect drives the `@MainActor` access controller, while the scan itself is
/// awaited (off the main actor — the cooperative pool runs ``LibraryScanning``).
public struct DropImporter: Sendable {
    private let scanner: any LibraryScanning
    private let isDirectory: @Sendable (URL) -> Bool

    /// The extensions a dropped loose file must carry to be imported — the
    /// scanner's canonical audio set, so a file is accepted iff the scanner can
    /// actually import it (single source of truth, no divergence).
    public static var audioExtensions: Set<String> {
        LibraryScanner.audioExtensions
    }

    /// - Parameters:
    ///   - scanner: the import pipeline (production `LibraryScanner` or a fake).
    ///   - isDirectory: probe deciding whether a URL is a folder (injectable for
    ///     hermetic tests; defaults to a `FileManager` check).
    public init(
        scanner: any LibraryScanning,
        isDirectory: @escaping @Sendable (URL) -> Bool = DropImporter.fileManagerIsDirectory
    ) {
        self.scanner = scanner
        self.isDirectory = isDirectory
    }

    /// Classifies `urls` into a ``DropImportPlan`` (pure given `isDirectory`):
    /// folders become new roots (deduped by standardized path against
    /// `existingRoots` and each other), audio files become loose imports, and
    /// everything else is rejected.
    public func plan(for urls: [URL], existingRoots: [URL]) -> DropImportPlan {
        var seenRootPaths = Set(existingRoots.map(\.standardizedFileURL.path))
        var plan = DropImportPlan()
        for url in urls {
            let standardized = url.standardizedFileURL
            if isDirectory(standardized) {
                let path = standardized.path
                if seenRootPaths.contains(path) {
                    plan.rejected.append(standardized)
                } else {
                    seenRootPaths.insert(path)
                    plan.roots.append(standardized)
                }
            } else if Self.audioExtensions.contains(standardized.pathExtension.lowercased()) {
                plan.looseFiles.append(standardized)
            } else {
                plan.rejected.append(standardized)
            }
        }
        return plan
    }

    /// Executes `plan`: registers each new folder via `addRoot` then scans it, and
    /// one-shot imports the loose audio files. Returns the combined tally. The
    /// scan is `await`ed, never blocking the main actor.
    @MainActor
    @discardableResult
    public func run(_ plan: DropImportPlan, addRoot: (URL) -> Void) async -> ScanSummary {
        var summary = ScanSummary()
        for root in plan.roots {
            addRoot(root)
            await summary.add(scanner.scan(.directory(root)))
        }
        if !plan.looseFiles.isEmpty {
            await summary.add(scanner.scan(.files(plan.looseFiles)))
        }
        return summary
    }

    /// The default folder probe: a `FileManager` directory check.
    public static let fileManagerIsDirectory: @Sendable (URL) -> Bool = { url in
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
