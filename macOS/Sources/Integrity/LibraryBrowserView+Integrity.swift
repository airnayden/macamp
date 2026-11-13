// LibraryBrowserView+Integrity — the "Verify Files…" action on a library selection.
//
// Split out of `LibraryBrowserActions.swift` to keep each source under the
// SwiftLint file-length limit; the member is internal because the view's menu in
// the parent file invokes it.
//
// It RESOLVES a selection and presents a sheet, and that is all. No file is
// opened here: the report's own `.task` starts the pass once the sheet is on
// screen, so the work begins with the listener looking at its progress. Nothing
// else in the app may call this — a scan, an import or a download must never
// trigger a verification, because verifying decodes every selected file end to
// end.
import Persistence
import SwiftUI
import ViewModels

extension LibraryBrowserView {
    /// Opens the verification report for the selection, in the order it is shown.
    func verifyFiles(_ ids: Set<Int64>) {
        let targets = IntegrityCheckTarget.targets(from: records(for: ids))
        guard !targets.isEmpty else { return }
        integrityReportRequest = IntegrityReportRequest(targets: targets)
    }
}
