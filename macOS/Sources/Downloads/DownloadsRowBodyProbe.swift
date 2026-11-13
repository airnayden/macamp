// DownloadsRowBodyProbe — the seam that makes "a tick re-renders ONE row" assertable.
//
// The multi-row download queue rests on an invalidation claim, not a value claim: every
// active row shows the right number either way, so a value test passes just as happily
// against an implementation that re-evaluates all N row bodies on every one of the
// several-per-second samples. What has to be measured is HOW MANY bodies SwiftUI ran.
//
// There is no way to observe that from outside a view, so the view reports it. This is
// the same shape as `Self._printChanges()`, wired to an environment closure instead of
// stderr: ``DownloadsActiveRow`` calls it with its own leaf id at the top of `body`, and
// `macOS/Tests/DownloadsRowInvalidationTests.swift` hosts three rows, ticks one leaf,
// and asserts exactly one id came back.
//
// In production the value is `nil`, so the call is one optional-chained no-op per row
// body and nothing here allocates, retains, or logs.
//
// This file constructs no `Process` and no `URLSession` — `macOS/Sources/Downloads` is
// scanned wholesale by `scripts/check-downloader-boundary.sh`.
import Foundation
import SwiftUI

/// Which of an active row's two bodies reported.
///
/// A download row is split in two on purpose, and the split is the whole optimization:
/// the wrapper renders the title and the cancel button and reads NO live state, while
/// the bar-and-caption leaf is the only view that reads
/// ``DownloadRowLeaf/state``. So a sample should move exactly one ``progress`` body and
/// no ``row`` body at all, and the two have to be counted apart to say that.
enum DownloadsRowBodyPart: Hashable {
    /// ``DownloadsActiveRow`` — title and cancel. A tick must never re-evaluate it.
    case row
    /// ``DownloadsProgressBar`` — the bar and its caption. A tick re-evaluates exactly
    /// the one belonging to the sampled row.
    case progress
}

extension EnvironmentValues {
    /// Invoked with a body's part and its row's leaf id each time that body is evaluated.
    ///
    /// `nil` everywhere in the shipping app; only a test injects a recorder.
    @Entry var downloadsRowBodyProbe: ((DownloadsRowBodyPart, UUID) -> Void)?
}
