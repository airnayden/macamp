// DownloadLibraryImporter — the one gate between a finished download and the library.
//
// The downloads folder is deliberately NOT a library root: nothing watches it, no
// migration knows about it, and no `libraryRoot` row names it. A finished file reaches
// the library through exactly ONE explicit `LibraryScanner.scan(.files([url]))`, fired
// from the queue's `onItemFinished` seam — which the engine emits on its own
// `after_move` path, so only a file that actually landed is ever imported.
//
// That import is now the listener's choice, and it is OFF by default. A download is a
// file someone asked for, not a library decision. When the switch is off the file still
// lands in the destination folder exactly as before — ONLY the scan is withheld — and
// the folder can be added as an ordinary library root (Preferences ▸ Library) to make
// downloads appear alongside everything else.
//
// ── WHY THIS TYPE EXISTS AT ALL ──────────────────────────────────────────────
//
// The wiring lives in the macOS shell (`AppEnvironment+Downloads.swift`), which
// `swift test` cannot reach. Putting the DECISION here — rather than as a `guard` in
// that closure — is what lets `DownloadsTests` drive the shipped gate over a real
// queue, a real scanner and a real database, instead of a restatement of it in a
// convenient fixture. The shell owns only the provider closure.
//
// The enablement is a `@Sendable` provider rather than a stored `Bool` for the same
// reason the queue's destination and format are: it is re-read at every finished item,
// so flipping the switch reaches the NEXT download with no relaunch and nothing to
// rebuild.
import Foundation

/// Imports one finished download into the library, when the listener has asked for that.
public struct DownloadLibraryImporter: Sendable {
    private let scanner: any LibraryScanning
    private let isAutoImportEnabled: @Sendable () -> Bool

    public init(scanner: any LibraryScanning, isAutoImportEnabled: @escaping @Sendable () -> Bool) {
        self.scanner = scanner
        self.isAutoImportEnabled = isAutoImportEnabled
    }

    /// Scans `fileURL` into the library and reports what that did, or `nil` when
    /// auto-import is off and NO scan was run.
    ///
    /// `nil` is the whole point of the return type: a caller that announces an import
    /// must be unable to announce one that never happened. It is distinct from an empty
    /// ``ScanSummary``, which means a scan ran and found nothing new.
    ///
    /// `.files([url])` and never `.directory(_:)` — the destination is the listener's
    /// own folder, may hold anything, and re-walking it per download would turn one
    /// import into an O(folder) rescan. The scanner deduplicates by `filePath`, so a
    /// re-download of the same video updates its row rather than adding a second.
    public func importFinished(at fileURL: URL) async -> ScanSummary? {
        guard isAutoImportEnabled() else { return nil }
        return await scanner.scan(.files([fileURL]))
    }
}
