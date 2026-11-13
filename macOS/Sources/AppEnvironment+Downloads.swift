// AppEnvironment+Downloads — YouTube-download composition wiring.
//
// Split out of `AppEnvironment.swift` to keep that composition-root file under the
// SwiftLint `file_length` budget, exactly as `AppEnvironment+Karaoke.swift` is. The
// leaf services (`YtDlpProcessRunner` → `DownloadToolManager` → `DownloadQueueService`)
// are assembled here, `AppEnvironment.downloads` is assigned, and the queue's three
// seams are connected to the library and the toast layer.
//
// ── THE DOWNLOADS FOLDER IS NOT A LIBRARY ROOT ───────────────────────────────
//
// Nothing here calls `LibraryAccessController.addRoot`, adds a GRDB migration, or
// attaches an FSEvents watcher. A finished download reaches the library through ONE
// explicit `LibraryScanner.scan(.files([url]))` per item, fired from
// `onItemFinished` — which the queue emits with the engine's own `after_move` path, so
// only a file that actually landed is ever imported.
//
// It stays visible to EVERY profile for free: it lives under no profile's
// `libraryRoot`, and `LibraryVisibility`'s ownerless clause ("under NO configured root
// ⇒ visible to everyone") therefore matches it for all of them. That is the whole
// mechanism — there is no per-profile bookkeeping to keep in step, which is also why
// changing the destination needs no cleanup: new items land in the new folder, and the
// old folder is left untouched.
//
// ── AND THE IMPORT IS OPT-IN ─────────────────────────────────────────────────
//
// `AppSettings.downloads.autoImportEnabled` gates that scan, and it ships OFF. The
// decision lives in `Services.DownloadLibraryImporter` rather than as a `guard` in the
// seam below, so `swift test --filter DownloadsTests` can drive the shipped gate over a
// real queue instead of a restatement of it. This file supplies only the provider
// closure and the box behind it.
//
// ── THE QUEUE IS PROFILE-AGNOSTIC ────────────────────────────────────────────
//
// A profile switch deliberately has NO orchestrator step here. The queue holds no
// profile id, reads none, and stores nothing per-profile, so switching mid-download
// leaves the in-flight row exactly as it was — the download the listener started
// finishes, and the file it produces is visible to whoever is now active. Pinned by
// `DownloadProfileSwitchTests`.
//
// ── WHY THE APP PROBES THE DESTINATION ITSELF ────────────────────────────────
//
// `isDirectoryWritable` is wired to `DownloadDestinationProbe`, which writes and
// deletes a probe file BEFORE any engine handoff. A yt-dlp child cannot raise a TCC
// prompt (see `DownloadDestination.swift`), so the app has to be the process that
// touches the folder first. A refusal becomes `.destinationUnavailable` for that one
// row; the driver moves on to the next, and the recovery toast points at the System
// Settings pane that grants access.
//
// ── SEAMS ARE DRAIN-SCOPED, NOT ROW-SCOPED ───────────────────────────────────
//
// Everything the queue SAYS is scoped to a drain — the span from the queue first
// holding work to the moment it holds none again — and never to a row. Several
// transfers run at once, so a row-scoped latch says the same sentence once per row and
// a row-scoped counter reports a fraction of the drain's work. Both policies therefore
// read the same `onQueueChanged` edge and both re-arm on it: `DownloadToastPolicy`
// (`Downloads/DownloadsUIWiring.swift`) owns the completion count and the first-failure
// sentence, and ``DownloadRecoveryPolicy`` below owns the unwritable-destination offer.
//
// This file constructs no `Process` and no `URLSession` — both live in the two files
// `scripts/check-downloader-boundary.sh` names, and are reached here only as the
// `ToolProcessRunning` / `ToolReleaseFetching` conformers they implement.
import Foundation
import Observation
import os
import Persistence
import Services

extension AppEnvironment {
    /// The download leaf services, assembled together because the tool manager needs a
    /// view of the queue and the queue needs the tool manager (resolved through
    /// ``DownloadBoxes/snapshot``, which breaks the cycle).
    struct DownloadsStack {
        /// Provisions and self-updates the engine. Retained by ``queue`` as its
        /// `DownloadToolProviding`, and again by `AppEnvironment.downloadTools` so the
        /// preferences pane can read the version and drive an update through the same
        /// instance the queue runs on — never a second manager over the same directory.
        let tools: DownloadToolManager
        /// The serial FIFO the whole feature drives.
        let queue: DownloadQueueService
        /// The ONE keyless oEmbed client, shared by the queue's paste-time decoration
        /// and the thumbnail store. Shared rather than built twice because each client
        /// owns its own ≤4 window — two of them would silently make the ceiling eight.
        let oEmbed: YouTubeOEmbedClient
    }

    /// The five values the queue, the tool manager and the library importer must read
    /// OFF the main actor, each boxed so `AppSettings` (which is `@MainActor`) is never
    /// touched from a `@Sendable` closure. Karaoke's `cacheDirectoryBox` precedent.
    struct DownloadBoxes {
        /// The configured destination folder, re-read by the queue at every dequeue —
        /// which is what makes a settings change apply to future items without
        /// disturbing the queue.
        let destination: OSAllocatedUnfairLock<URL>
        /// The configured container/quality, re-read at dequeue for the same reason.
        let format: OSAllocatedUnfairLock<DownloadFormat>
        /// The latest queue snapshot, written by `onQueueChanged`.
        ///
        /// This is how ``DownloadToolManager`` learns a download is in flight so it can
        /// refuse to replace the engine binary underneath a running child. A box rather
        /// than a direct read because `DownloadQueueing` publishes snapshots and vends
        /// no getter — and because it is what lets the manager be built BEFORE the queue
        /// it observes.
        let snapshot: OSAllocatedUnfairLock<DownloadQueueSnapshot>
        /// Whether a finished download is added to the library, re-read by
        /// ``DownloadLibraryImporter`` at every finished item — which is what makes a
        /// flip of the switch reach the NEXT download with no relaunch.
        let autoImport: OSAllocatedUnfairLock<Bool>
        /// How many transfers may run at once, re-read by the queue's pump at every
        /// refill — so lowering it lets the extant rows finish and simply stops
        /// refilling, and raising it takes effect on the next row picked up. Never
        /// retroactive: a transfer already running is not interrupted either way.
        let maxConcurrent: OSAllocatedUnfairLock<Int>
    }

    /// Builds the download graph, assigns ``downloads`` and ``downloadTools``, and
    /// connects the queue's seams.
    ///
    /// Called from `live()` after the environment exists. Nothing is prepared eagerly:
    /// `DownloadToolManager.prepare()` copies ~110 MB of binaries out of the bundle on
    /// a first run, so it is left to the queue's own lazy tool resolution rather than
    /// put on the launch path.
    func connectDownloads(settings: AppSettings) {
        let boxes = Self.makeDownloadBoxes(settings: settings)
        let stack = Self.makeDownloadsStack(boxes: boxes)
        downloads = stack.queue
        downloadTools = stack.tools
        wireDownloadSeams(stack.queue, boxes: boxes, chatFinishedRoute: connectChatDownloads(boxes: boxes))
        connectDownloadsUI(stack.queue, oEmbed: stack.oEmbed)
        connectChatDownloadQueueSeams(stack.queue)
        connectChatDownloadSeams()
        observeDownloadPreferences(settings: settings, boxes: boxes)
    }

    /// Seeds the boxes from `AppSettings` once, here on the main actor.
    static func makeDownloadBoxes(settings: AppSettings) -> DownloadBoxes {
        let preferences = settings.downloads
        return DownloadBoxes(
            destination: OSAllocatedUnfairLock(
                initialState: DownloadDestinationLocation.resolve(configuredPath: preferences.destinationPath)
            ),
            format: OSAllocatedUnfairLock(
                initialState: .audio(preferences.audioFormat, preferences.audioQuality)
            ),
            snapshot: OSAllocatedUnfairLock(initialState: .empty),
            autoImport: OSAllocatedUnfairLock(initialState: preferences.autoImportEnabled),
            maxConcurrent: OSAllocatedUnfairLock(initialState: preferences.maxConcurrent)
        )
    }

    /// Assembles the runner, the tool manager and the queue.
    ///
    /// ONE `YtDlpProcessRunner` is shared: the tool manager runs `--version` and
    /// `codesign` through it while the queue runs transfers, and both are stateless with
    /// respect to each other (every spawn owns its own child and its own stream).
    static func makeDownloadsStack(boxes: DownloadBoxes) -> DownloadsStack {
        let runner = YtDlpProcessRunner()
        let snapshotBox = boxes.snapshot
        let tools = DownloadToolManager(
            releaseFetcher: DownloadToolReleaseClient(),
            processRunner: runner,
            toolsDirectory: DownloadPrivateDirectories.tools,
            queueSnapshot: { snapshotBox.withLock { $0 } }
        )
        let destinationBox = boxes.destination
        let formatBox = boxes.format
        let concurrencyBox = boxes.maxConcurrent
        let oEmbed = YouTubeOEmbedClient()
        let queue = DownloadQueueService(
            toolProvider: tools,
            processRunner: runner,
            stagingDirectory: DownloadPrivateDirectories.staging,
            destinationDirectory: { destinationBox.withLock { $0 } },
            downloadFormat: { formatBox.withLock { $0 } },
            isDirectoryWritable: { DownloadDestinationProbe.isWritable($0) },
            maxConcurrent: { concurrencyBox.withLock { $0 } },
            oEmbedFetcher: oEmbed
        )
        return DownloadsStack(tools: tools, queue: queue, oEmbed: oEmbed)
    }
}

// MARK: - Seams

private extension AppEnvironment {
    /// Connects the queue's three seams.
    ///
    /// Every assignment CHAINS the handler already installed (the `wireNowPlayingFeed`
    /// precedent) rather than replacing it: `DownloadQueueing` vends one slot per seam,
    /// and the download UI wires the same slots for its own projection. Chaining on both
    /// sides means neither wiring order can silently drop the other.
    ///
    /// `MainActor.assumeIsolated` states the seams' own documented contract — they are
    /// invoked on the main actor — rather than dodging it, and it keeps the handlers
    /// synchronous so the driver's awaited-publish ordering guarantee still holds.
    /// - Parameter chatFinishedRoute: decides AND handles a finished download the chat
    ///   surface registered a playlist append for. It is invoked inside the finished
    ///   closure's own `MainActor.assumeIsolated`, BEFORE the legacy import task is
    ///   spawned, because the seam is synchronous and a check made inside that task
    ///   could lose the race to the legacy scan. Answering `true` means the route has
    ///   taken ownership: this method then skips `importFinishedDownload` and its toast,
    ///   so the file is scanned exactly once and announced once. `false` and `nil` leave
    ///   today's path byte for byte, and history recording is unconditional either way.
    func wireDownloadSeams(
        _ queue: DownloadQueueService,
        boxes: DownloadBoxes,
        chatFinishedRoute: (@MainActor @Sendable (DownloadItem, URL) -> Bool)? = nil
    ) {
        let snapshotBox = boxes.snapshot
        let recovery = DownloadRecoveryPolicy()
        let previousSnapshotHandler = queue.onQueueChanged
        queue.onQueueChanged = { snapshot in
            previousSnapshotHandler?(snapshot)
            snapshotBox.withLock { $0 = snapshot }
            MainActor.assumeIsolated { recovery.noteQueue(snapshot) }
        }

        let previousProgressHandler = queue.onItemProgress
        queue.onItemProgress = { [weak self] id, state in
            previousProgressHandler?(id, state)
            MainActor.assumeIsolated {
                self?.handleDownloadState(state, recovery: recovery)
            }
        }

        let autoImportBox = boxes.autoImport
        let importer = DownloadLibraryImporter(
            scanner: scanner,
            isAutoImportEnabled: { autoImportBox.withLock { $0 } }
        )
        // Retained BY the seam closure, which is the only thing that talks to it. It
        // is deliberately not an `AppEnvironment` property: nothing reads download
        // history through the recorder — todo 14's tab reads the repository directly.
        let formatBox = boxes.format
        let historyRecorder = DownloadHistoryRecorder(
            history: DownloadHistoryRepository(database),
            fallbackFormat: { formatBox.withLock { $0 } },
            didRecord: { [weak self] in self?.downloadHistoryRevision &+= 1 }
        )
        let previousFailedHandler = queue.onItemFailed
        queue.onItemFailed = { item, error in
            previousFailedHandler?(item, error)
            MainActor.assumeIsolated { historyRecorder.recordFailure(item, error: error) }
        }
        let previousFinishedHandler = queue.onItemFinished
        queue.onItemFinished = { [weak self] item, fileURL in
            previousFinishedHandler?(item, fileURL)
            let routed = MainActor.assumeIsolated { () -> Bool in
                historyRecorder.record(item, at: fileURL)
                return chatFinishedRoute?(item, fileURL) ?? false
            }
            guard !routed else { return }
            Task { @MainActor [weak self] in
                await self?.importFinishedDownload(at: fileURL, using: importer)
            }
        }
    }

    /// Surfaces the one failure a listener can act on.
    ///
    /// `.destinationUnavailable` is the only state handled here because it is the only
    /// one with a recovery: the folder is unwritable, and macOS has a pane that fixes
    /// that. Every other failure already carries its own copy through
    /// `DownloadError.message`, which the download UI renders per row; duplicating it as
    /// a toast would report the same fault twice.
    ///
    /// How OFTEN it may speak is ``DownloadRecoveryPolicy``'s decision, not this
    /// method's — which is also what makes the decision assertable, since asking this
    /// method would open System Settings on the machine running the test.
    func handleDownloadState(_ state: DownloadState, recovery: DownloadRecoveryPolicy) {
        guard recovery.shouldOffer(for: state) else { return }
        toast.show(
            text: String(localized: MacAMPStrings.downloadDestinationGrantAccessToast),
            icon: "exclamationmark.triangle.fill"
        )
        SystemSettingsLauncher().openFilesAndFoldersPrivacy()
    }

    /// Offers one finished download to the library, and announces it only if it went in.
    ///
    /// The scan itself — and whether one happens at all — belongs to `importer`; the
    /// only thing decided here is the toast. `announces(_:)` is what keeps that honest:
    /// with auto-import off the importer answers `nil`, so there is no summary to
    /// misread as a successful import.
    ///
    /// # Why N of these run at once, unserialized
    ///
    /// `onItemFinished` fires once per finished row, so several parallel transfers spawn
    /// several of these tasks within milliseconds of each other. They are deliberately
    /// NOT funnelled through a serial queue, because the only thing that would need
    /// protecting is already protected one layer down:
    ///
    ///   * `LibraryScanning` (`Services/Scanner/LibraryScanning.swift`) is a plain
    ///     `Sendable` protocol and `LibraryScanner` a `public struct` — not an actor and
    ///     not `@MainActor` — and `events(for:)` wraps every call in its OWN `Task`. The
    ///     scanner serializes nothing by itself; overlapping scans really do interleave.
    ///   * Interleaving is harmless because the only state a `.files([url])` scan shares
    ///     with a sibling is the database, and `persistChunk`
    ///     (`Services/Scanner/LibraryScanner+Chunk.swift`) does all of its work —
    ///     `resolveGraph` → `stampGraph` → `findOrCreateArtist`/`findOrCreateAlbum` AND
    ///     every insert and update — inside ONE `database.writer.write { }`. GRDB's pool
    ///     has a single serialized writer, so the find-or-create read and the insert
    ///     depending on it cannot be split by another scan, and two downloads by the
    ///     same artist cannot mint two artist rows. Everything else on the path
    ///     (`resolveCandidates`, `classify`, `stage`, `readMetadata`) is per-call local
    ///     state on a value type.
    ///
    /// A wiring-side funnel would therefore serialize work GRDB already serializes, and
    /// would make parallel downloads import strictly one after another for no
    /// correctness gain. Its absence is the decision, not an oversight.
    func importFinishedDownload(at fileURL: URL, using importer: DownloadLibraryImporter) async {
        let decision = await importer.importFinished(at: fileURL)
        guard DownloadImportAnnouncement.announces(decision) else { return }
        toast.show(text: String(localized: MacAMPStrings.downloadImportedToast), icon: "square.and.arrow.down")
    }

    /// Re-reads the download preferences into the boxes whenever they change, and
    /// re-arms itself — the same event-driven, self-re-arming shape
    /// `observeIntelligenceToggle(settings:)` and `observeKaraokeReadiness()` use, so
    /// the Downloads pane keeps its no-`.onChange` contract.
    ///
    /// `downloads` is read WHOLE because it is the single stored property `@Observable`
    /// instruments; that covers the destination and both format fields at once.
    /// `onChange` fires BEFORE the write lands, hence the main-actor hop before
    /// re-reading.
    func observeDownloadPreferences(settings: AppSettings, boxes: DownloadBoxes) {
        withObservationTracking {
            _ = settings.downloads
        } onChange: { [weak self, weak settings] in
            Task { @MainActor in
                guard let self, let settings else { return }
                let preferences = settings.downloads
                boxes.destination.withLock {
                    $0 = DownloadDestinationLocation.resolve(configuredPath: preferences.destinationPath)
                }
                boxes.format.withLock { $0 = .audio(preferences.audioFormat, preferences.audioQuality) }
                boxes.autoImport.withLock { $0 = preferences.autoImportEnabled }
                boxes.maxConcurrent.withLock { $0 = preferences.maxConcurrent }
                self.observeDownloadPreferences(settings: settings, boxes: boxes)
            }
        }
    }
}
