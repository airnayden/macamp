// LibraryBrowserView+Loudness — the two loudness actions on a library selection.
//
// Split out of `LibraryBrowserActions.swift` to keep each source under the SwiftLint
// file-length limit; the members are internal because the view's menu in the parent
// file invokes them.
//
// The asymmetry between the two is deliberate and is the whole safety model.
// "Analyze Loudness" only READS audio and writes MacAMP's own cache, so it fires
// straight away. "Write ReplayGain Tags…" modifies files the listener owns, so it
// only ever builds a PLAN and hands it to ``ReplayGainWriteSheet``; nothing is
// written until that sheet's confirm button is pressed. The ellipsis in the menu
// title is the contract.
import Persistence
import SwiftUI
import ViewModels

extension LibraryBrowserView {
    /// Measures the selected tracks' loudness, in the order the listener sees them.
    func analyzeLoudness(_ ids: Set<Int64>) {
        let trackIds = records(for: ids).compactMap(\.id)
        guard !trackIds.isEmpty else { return }
        let count = trackIds.count
        Task {
            await environment.loudness.scan.analyze(trackIds: trackIds)
            environment.toast.show(
                text: String(localized: ReplayGainTagStrings.analyzeToast(count)),
                icon: "waveform.badge.magnifyingglass"
            )
        }
    }

    /// Partitions the selection and presents the confirmation. Writes nothing.
    func requestReplayGainWrite(_ ids: Set<Int64>) {
        let targets = records(for: ids).compactMap { record in
            record.id.map { ReplayGainTagTarget(trackId: $0, filePath: record.filePath) }
        }
        guard !targets.isEmpty else { return }
        replayGainWriteRequest = ReplayGainWriteRequest(
            plan: environment.loudness.tagWriter.plan(for: targets)
        )
    }
}
