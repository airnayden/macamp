// DocumentImporter — turns picked URLs into library tracks under scoped access.
//
// The document picker hands back security-scoped URLs (files and/or folders).
// This controller, for each pick: retains scoped access in the app's shared
// access owner for subsequent playback and metadata reads, persists a bookmark so
// the root can be re-opened later, materializes any iCloud / file-provider items
// that are not yet on disk (``FileMaterializer``), then drives the shared
// ``LibraryScanning`` over the selection and republishes its progress.
//
// It is `@MainActor @Observable` so the toolbar button can bind directly to
// ``progress`` / ``isImporting``; the heavy work (metadata read, persistence)
// happens off-main inside the scanner. Logic is testable through the
// ``FileImporting`` seam (a fake ships below) + the injected scanner/store fakes.
import Foundation
import Observation
import Services

// MARK: - ImportProgress

/// A republished slice of ``ScanProgress`` for the UI (no Services types leak
/// into the view layer).
struct ImportProgress: Equatable {
    var processed: Int
    var total: Int
    var fraction: Double
}

// MARK: - FileImporting

/// The seam the toolbar button depends on: present-and-import with observable
/// progress. A fake (``FakeFileImporter``) drives previews without touching disk.
@MainActor
protocol FileImporting: AnyObject {
    /// Latest progress, or `nil` while idle.
    var progress: ImportProgress? { get }
    /// True between the first pick and the final summary.
    var isImporting: Bool { get }
    /// Imports the picked files / folders. No-ops on empty input.
    func importPicked(_ urls: [URL]) async
}

// MARK: - DocumentImporter

/// Production ``FileImporting`` over the shared scanner + bookmark store.
@MainActor
@Observable
final class DocumentImporter: FileImporting {
    /// Where the import currently is.
    enum Phase: Equatable {
        case idle
        case preparing
        case scanning
        case finished(ScanSummary)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: ImportProgress?

    @ObservationIgnored private let scanner: any LibraryScanning
    @ObservationIgnored private let bookmarks: SecurityScopedBookmarkManager
    @ObservationIgnored private let accessOwner: SecurityScopedAccessOwner
    @ObservationIgnored private let materializer: any FileMaterializing

    init(
        scanner: any LibraryScanning,
        bookmarks: SecurityScopedBookmarkManager,
        accessOwner: SecurityScopedAccessOwner = SecurityScopedAccessOwner(),
        materializer: any FileMaterializing = FileMaterializer()
    ) {
        self.scanner = scanner
        self.bookmarks = bookmarks
        self.accessOwner = accessOwner
        self.materializer = materializer
    }

    var isImporting: Bool {
        phase == .preparing || phase == .scanning
    }

    func importPicked(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        phase = .preparing
        progress = nil

        accessOwner.retainAccess(to: urls)

        for url in urls {
            try? bookmarks.persist(url)
        }

        let plan = Self.plan(for: urls)
        await materialize(plan)

        phase = .scanning
        var summary = ScanSummary()
        for request in plan.requests {
            if Task.isCancelled { break }
            await summary.add(scan(request))
        }
        phase = .finished(summary)
    }
}

// MARK: - Planning + scanning

private extension DocumentImporter {
    /// Picked roots partitioned into directory scans + one batched file scan.
    struct ImportPlan {
        var directories: [URL]
        var files: [URL]
        var requests: [ScanRequest]
    }

    static func plan(for urls: [URL]) -> ImportPlan {
        var directories: [URL] = []
        var files: [URL] = []
        for url in urls {
            if isDirectory(url) {
                directories.append(url)
            } else {
                files.append(url)
            }
        }
        var requests = directories.map(ScanRequest.directory)
        if !files.isEmpty {
            requests.append(.files(files))
        }
        return ImportPlan(directories: directories, files: files, requests: requests)
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
    }

    func materialize(_ plan: ImportPlan) async {
        for url in plan.files {
            await materializer.materialize(url)
        }
        for directory in plan.directories {
            await materializer.materializeContents(of: directory)
        }
    }

    func scan(_ request: ScanRequest) async -> ScanSummary {
        var summary = ScanSummary()
        for await event in scanner.events(for: request) {
            switch event {
            case let .progress(value):
                progress = ImportProgress(
                    processed: value.processed,
                    total: value.total,
                    fraction: value.fraction
                )
            case let .finished(value):
                summary = value
            }
        }
        return summary
    }
}

// MARK: - FileMaterializing

/// Ensures possibly-non-materialized (iCloud / file-provider) items are local
/// before the scanner reads them.
protocol FileMaterializing: Sendable {
    /// Triggers a download for `url` if it is a not-yet-current ubiquitous item,
    /// then coordinates a read to wait for the provider to hand over the bytes.
    func materialize(_ url: URL) async
    /// Best-effort materialization of a directory and (bounded) its children.
    func materializeContents(of directory: URL) async
}

/// Production ``FileMaterializing`` via `NSFileCoordinator` +
/// `startDownloadingUbiquitousItem`.
struct FileMaterializer: FileMaterializing {
    /// Cap on children eagerly triggered for download (the scanner's own walk
    /// reads the rest on demand).
    static let childLimit = 5000

    private let queue = DispatchQueue(label: "si.macamp.MacAMP.ios.file-coordination")

    func materialize(_ url: URL) async {
        triggerDownloadIfNeeded(url)
        await coordinateRead(url)
    }

    func materializeContents(of directory: URL) async {
        triggerDownloadIfNeeded(directory)
        await coordinateRead(directory)
        for child in enumerateChildren(directory) {
            triggerDownloadIfNeeded(child)
        }
    }

    private func triggerDownloadIfNeeded(_ url: URL) {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true,
              values.ubiquitousItemDownloadingStatus != .current
        else {
            return
        }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    private func coordinateRead(_ url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                var coordinatorError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { _ in }
                continuation.resume()
            }
        }
    }

    private func enumerateChildren(_ directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isUbiquitousItemKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            urls.append(url)
            if urls.count >= Self.childLimit { break }
        }
        return urls
    }
}

// MARK: - FakeFileImporter

/// A no-op ``FileImporting`` for previews: records the picked URLs and reports a
/// completed import without touching disk, audio or the database.
@MainActor
@Observable
final class FakeFileImporter: FileImporting {
    private(set) var progress: ImportProgress?
    private(set) var isImporting = false
    private(set) var importedURLs: [URL] = []

    func importPicked(_ urls: [URL]) async {
        importedURLs = urls
        progress = ImportProgress(processed: urls.count, total: max(urls.count, 1), fraction: 1)
    }
}
