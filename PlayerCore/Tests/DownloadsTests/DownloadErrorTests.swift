// The typed error ladder: localized copy, diagnostic passthrough, and the
// cancellation classification the UI uses to stay silent.
import Foundation
import Services
import Testing

@Suite("Download error ladder")
struct DownloadErrorTests {
    static let allShapes: [DownloadError] = [
        .downloadFailed(detail: nil),
        .invalidArguments,
        .engineRestartRequired,
        .cancelled,
        .cancelledByEngine,
        .alreadyDownloaded,
        .destinationUnavailable,
        .toolMissing,
        .updateFailed(detail: nil),
        .unknown(code: 137),
    ]

    @Test("every case resolves non-empty localized copy", arguments: allShapes)
    func messagesResolve(error: DownloadError) {
        #expect(!String(localized: error.message).isEmpty)
        #expect(error.errorDescription == String(localized: error.message))
    }

    @Test("distinct cases carry distinct copy")
    func messagesAreDistinct() {
        let messages = Set(Self.allShapes.map { String(localized: $0.message) })
        #expect(messages.count == Self.allShapes.count)
    }

    /// Engine output is untranslatable and often English-only, so it never becomes the
    /// primary message — it rides `detail` / `failureReason` for logs instead.
    @Test("diagnostics ride detail, never the localized message")
    func diagnosticsStayOutOfTheMessage() {
        let detail = "ERROR: unable to download video data: HTTP Error 403"
        let failed = DownloadError.downloadFailed(detail: detail)
        #expect(failed.detail == detail)
        #expect(failed.failureReason == detail)
        #expect(String(localized: failed.message) == String(localized: DownloadsStrings.errorDownloadFailed))
        #expect(!String(localized: failed.message).contains("403"))
    }

    @Test("only the two value-carrying cases expose a detail")
    func detailIsNilElsewhere() {
        #expect(DownloadError.updateFailed(detail: "checksum mismatch").detail == "checksum mismatch")
        #expect(DownloadError.toolMissing.detail == nil)
        #expect(DownloadError.unknown(code: 9).detail == nil)
        #expect(DownloadError.cancelled.detail == nil)
    }

    @Test("cancellations are classified apart from real faults")
    func cancellationClassification() {
        #expect(DownloadError.cancelled.isCancellation)
        #expect(DownloadError.cancelledByEngine.isCancellation)
        for error in Self.allShapes where error != .cancelled && error != .cancelledByEngine {
            #expect(!error.isCancellation)
        }
    }

    @Test("associated values participate in equality")
    func equalityIncludesPayloads() {
        #expect(DownloadError.downloadFailed(detail: "a") != .downloadFailed(detail: "b"))
        #expect(DownloadError.downloadFailed(detail: nil) == .downloadFailed(detail: nil))
        #expect(DownloadError.unknown(code: 1) != .unknown(code: 2))
        #expect(DownloadError.updateFailed(detail: "x") == .updateFailed(detail: "x"))
    }

    @Test("errors are hashable, so they can key diagnostics")
    func hashability() {
        let set: Set<DownloadError> = [.cancelled, .cancelled, .toolMissing]
        #expect(set.count == 2)
    }
}
