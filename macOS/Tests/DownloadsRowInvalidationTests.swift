// Todo 6 acceptance: the multi-row download queue's central claim is an INVALIDATION
// claim, and no value test can reach it.
//
// Every active row renders the right number whether the implementation gives each row
// its own observable leaf or keeps one `[UUID: DownloadState]` map on the store. The
// difference is only in how many view bodies SwiftUI re-evaluates per sample — one, or
// all N — and with four parallel transfers each reporting several samples a second that
// is the whole performance argument (SKILL macOS UI perf rule 3).
//
// So this suite counts BODIES, not values. It hosts three rows in a real
// `NSHostingView`, ticks one leaf through the store, and asserts exactly one row body
// ran. The repo had no body-evaluation probe before this; ``DownloadsRowBodyProbe`` is
// the seam, and this is its only consumer.
//
// PROVEN TO HAVE TEETH: mutating `DownloadsActiveRow` to read a store-wide state map
// instead of its own leaf makes `tickingOneLeafReEvaluatesOnlyThatRowsBody` report all
// three ids and fail. See `.omo/evidence/dlv2-06.txt`.
//
// This suite lives in `macampMacTests`, not `ViewModelTests`: hosting a view needs
// SwiftUI + AppKit, which the PlayerCore package's test target has no business
// importing.
import AppKit
import Foundation
@testable import MacAMP
import Services
import SwiftUI
import Testing
import ViewModels

/// Collects which bodies SwiftUI evaluated, and for which row.
@MainActor
final class DownloadsRowBodyRecorder {
    private(set) var evaluated: [(part: DownloadsRowBodyPart, id: UUID)] = []

    func record(_ part: DownloadsRowBodyPart, _ id: UUID) {
        evaluated.append((part, id))
    }

    func reset() {
        evaluated.removeAll()
    }

    func ids(for part: DownloadsRowBodyPart) -> [UUID] {
        evaluated.filter { $0.part == part }.map(\.id)
    }
}

/// Three active rows and nothing else — deliberately NOT the whole `DownloadsQueueView`.
///
/// `List` is lazy, so hosting the real pane would make "did this row's body run?"
/// depend on scroll-view materialization rather than on observation. A plain `VStack`
/// puts all three bodies in the tree unconditionally, which is what makes the count
/// mean something.
private struct DownloadsRowProbeHost: View {
    let leaves: [DownloadRowLeaf]
    let record: (DownloadsRowBodyPart, UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(leaves.enumerated()), id: \.element.id) { index, leaf in
                DownloadsActiveRow(leaf: leaf, position: index, isPaused: false) {}
            }
        }
        .frame(width: 360)
        .environment(\.downloadsRowBodyProbe, record)
        .designTokens(.standard)
    }
}

@MainActor
@Suite(.serialized)
struct DownloadsRowInvalidationTests {
    private static func item(_ videoID: String) -> DownloadItem {
        DownloadItem(
            canonicalVideoID: videoID,
            sourceURL: URL(string: "https://www.youtube.com/watch?v=\(videoID)")
                ?? URL(fileURLWithPath: videoID)
        )
    }

    private static let sample = DownloadState.downloading(
        fraction: 0.5,
        speedBytesPerSec: nil,
        etaSeconds: nil
    )

    @Test func tickingOneLeafReEvaluatesOnlyThatRowsBody() async {
        let store = DownloadQueueStore()
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: ["aaa", "bbb", "ccc"].map { Self.item($0) },
            pendingItems: [],
            isPaused: false
        ))
        let leaves = store.activeRows
        #expect(leaves.count == 3)

        let recorder = DownloadsRowBodyRecorder()
        let harness = DownloadsRowHostHarness(leaves: leaves, recorder: recorder)
        defer { harness.tearDown() }
        await harness.settle()

        // The probe must be live before anything is measured: a probe that never fires
        // satisfies "zero siblings" while measuring nothing at all, which is exactly how
        // a guard in this plan has passed against a broken implementation before.
        #expect(
            Set(recorder.ids(for: .progress)) == Set(leaves.map(\.id)),
            "all three bars must lay out once before the measurement, or the probe is dead"
        )

        recorder.reset()
        store.ingestProgress(id: leaves[0].id, state: Self.sample)
        await harness.settle()

        #expect(
            recorder.ids(for: .progress) == [leaves[0].id],
            "one row's sample must re-evaluate that row's bar and no sibling's: got \(recorder.evaluated)"
        )
        #expect(
            recorder.ids(for: .row).isEmpty,
            "a sample carries no title change, so no row wrapper should be re-evaluated at all"
        )
    }

    /// The same measurement from the other side: ticking each row in turn must move
    /// exactly its own body, so no single row is accidentally the only isolated one.
    @Test func eachRowIsIndependentlyInvalidated() async {
        let store = DownloadQueueStore()
        store.ingest(sequence: 0, snapshot: DownloadQueueSnapshot(
            activeItems: ["aaa", "bbb", "ccc"].map { Self.item($0) },
            pendingItems: [],
            isPaused: false
        ))
        let leaves = store.activeRows
        let recorder = DownloadsRowBodyRecorder()
        let harness = DownloadsRowHostHarness(leaves: leaves, recorder: recorder)
        defer { harness.tearDown() }
        await harness.settle()

        for (index, leaf) in leaves.enumerated() {
            recorder.reset()
            store.ingestProgress(
                id: leaf.id,
                state: .downloading(fraction: 0.1 * Double(index + 1), speedBytesPerSec: nil, etaSeconds: nil)
            )
            await harness.settle()
            #expect(
                recorder.ids(for: .progress) == [leaf.id],
                "row \(index) should be the only bar re-evaluated: got \(recorder.evaluated)"
            )
        }
    }
}

/// Hosts the probe view in a real, offscreen window and drains SwiftUI's pending
/// updates on demand.
///
/// A window is required: `NSHostingView` only runs its update pass once it belongs to
/// one. The window is deliberately placed far offscreen rather than hidden, because a
/// view in an invisible window is never asked to lay out at all.
@MainActor
private final class DownloadsRowHostHarness {
    private let window: NSWindow
    private let host: NSView

    init(leaves: [DownloadRowLeaf], recorder: DownloadsRowBodyRecorder) {
        let hosting = NSHostingView(
            rootView: DownloadsRowProbeHost(leaves: leaves) { recorder.record($0, $1) }
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        host = hosting
        window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
    }

    func tearDown() {
        window.orderOut(nil)
        window.contentView = nil
    }

    /// Lets SwiftUI deliver whatever observation changes are outstanding.
    ///
    /// `layoutSubtreeIfNeeded()` alone is not enough — an `@Observable` write schedules
    /// the update on the main run loop, so the actor has to be yielded before the layout
    /// pass can see it. Several short rounds rather than one long sleep so the test stays
    /// fast when the first round already settles it.
    func settle() async {
        for _ in 0 ..< 12 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()
    }
}

/// Todo 6 acceptance: pause honesty. A transfer already running is untouched by pause
/// (todo 3's refill-stop semantics), so its caption must never claim otherwise — the
/// paused fact is stated once, in the queue header.
@MainActor
struct DownloadsQueueCaptionTests {
    private static let everyState: [DownloadState?] = [
        nil,
        .queued,
        .fetchingMetadata,
        .downloading(fraction: 0.42, speedBytesPerSec: 2048, etaSeconds: 9),
        .postProcessing(fraction: nil),
        .finished(fileURL: URL(fileURLWithPath: "/tmp/out.m4a")),
        .cancelled,
        .failed(.toolMissing),
    ]

    @Test func aPausedQueueDoesNotRelabelADownloadingRow() {
        let downloading = DownloadState.downloading(fraction: 0.42, speedBytesPerSec: nil, etaSeconds: nil)

        #expect(
            String(localized: DownloadStateCaption.currentText(for: downloading, isPaused: true))
                == String(localized: MacAMPStrings.downloadsStateDownloading)
        )
    }

    /// The override is gone for every phase, not just the one that used to be visible
    /// most often — a partial removal would be a subtler version of the same lie.
    @Test func theIsPausedFlagChangesNoCaption() {
        for state in Self.everyState {
            #expect(
                String(localized: DownloadStateCaption.currentText(for: state, isPaused: true))
                    == String(localized: DownloadStateCaption.currentText(for: state, isPaused: false))
            )
        }
    }

    /// The paused notice replaced the row caption, and it says what pause actually does.
    @Test func thePausedNoticeNamesOnlyTheHeldBackWork() {
        let notice = String(localized: MacAMPStrings.downloadsQueuePausedNotice)

        #expect(notice == "No new downloads will start")
    }

    // MARK: - Conversion (todo 9)

    /// The load-bearing claim of the whole union: only the BAR's determinacy follows the
    /// fraction. `.postProcessing`'s payload legitimately goes `nil → value → nil` inside
    /// one phase — indeterminate until ffmpeg's first block, real while blocks arrive,
    /// indeterminate again from `progress=end` because the embed passes still have to run
    /// — and a caption that tracked it would rewrite itself two or three times per
    /// download. Byte identity across all three, not merely "some label is present".
    @Test func theCaptionIsIdenticalAcrossEveryConversionFraction() {
        let format = DownloadFormat.audio(.mp3, .best)
        let captions = [nil, 0.4, nil].map { fraction in
            String(localized: DownloadStateCaption.currentText(
                for: .postProcessing(fraction: fraction),
                format: format,
                isPaused: false
            ))
        }

        #expect(Set(captions).count == 1)
        #expect(captions.first == "Converting to MP3…")
    }

    /// The staged label names the container being produced, on the indeterminate branch
    /// as much as on any other — a remux, an unknown duration and a conversion too fast
    /// to sample must all read the same.
    @Test(
        "each container has its own staged label",
        arguments: [
            (DownloadAudioFormat.m4a, "Converting to M4A…"),
            (DownloadAudioFormat.mp3, "Converting to MP3…"),
            (DownloadAudioFormat.opus, "Converting to Opus…"),
            (DownloadAudioFormat.flac, "Converting to FLAC…"),
        ]
    )
    func eachContainerHasItsOwnStagedLabel(format: DownloadAudioFormat, expected: String) {
        let caption = String(localized: DownloadStateCaption.currentText(
            for: .postProcessing(fraction: nil),
            format: .audio(format, .best),
            isPaused: false
        ))

        #expect(caption == expected)
    }

    /// The driver stamps the format just before the transfer spawns, so a row can be
    /// post-processing with none only if something went very wrong — the generic label
    /// is what it reads then, rather than a blank or a guessed container.
    @Test func anUnstampedRowKeepsTheGenericConversionLabel() {
        let caption = String(localized: DownloadStateCaption.currentText(
            for: .postProcessing(fraction: 0.4),
            format: nil,
            isPaused: false
        ))

        #expect(caption == "Converting audio…")
    }
}
