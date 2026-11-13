// The pure classifier's whole truth table, plus a compile-time coverage lock.
//
// The table below is written out case by case rather than derived, because the thing
// under test IS the mapping — a test that computed the expectation from the same switch
// would assert nothing. Every `DownloadState` case appears, and the `.failed` case
// appears once per `DownloadError` case, so the table has 16 rows for two enums holding
// 7 and 10 cases.
//
// ``ChatFailurePolicyCoverage/tag(for:)`` is the lock that keeps it that way. It is an
// EXHAUSTIVE switch over both enums with no `default`, so adding a case to either one
// stops this file compiling; and ``ChatFailurePolicyCoverage/requiredTags`` is asserted
// against the table's own tags, so a case that compiles but was never added to the table
// fails the coverage test. The plan's requirement — "a new state must not compile
// silently into `.ignore`" — needs both halves: the production switch refuses to build,
// and this file refuses to let the row be forgotten.
//
// Two payload-independence tests sit beside the table because the associated values are
// the one thing a table of fixed rows cannot speak for: `.downloadFailed` must classify
// the same with and without engine diagnostics, and `.postProcessing` the same with and
// without an ffmpeg sample.
import Foundation
import Services
import Testing

/// One row of the classification table.
struct ChatFailurePolicyCase {
    let state: DownloadState
    let expected: ChatDownloadFailurePolicy.Classification
}

/// The table itself, plus the exhaustive tagger that keeps it honest.
enum ChatFailurePolicyCoverage {
    static let table: [ChatFailurePolicyCase] = [
        // Non-terminal: the row is still moving, so there is nothing to evict yet.
        ChatFailurePolicyCase(state: .queued, expected: .ignore),
        ChatFailurePolicyCase(state: .fetchingMetadata, expected: .ignore),
        ChatFailurePolicyCase(
            state: .downloading(fraction: 0.5, speedBytesPerSec: 1024, etaSeconds: 30),
            expected: .ignore
        ),
        ChatFailurePolicyCase(state: .postProcessing(fraction: nil), expected: .ignore),
        // Terminal success belongs to the finished seam, not to this policy.
        ChatFailurePolicyCase(
            state: .finished(fileURL: URL(fileURLWithPath: "/tmp/macamp-finished.m4a")),
            expected: .ignore
        ),
        // The person chose it — both shapes, so neither ordering matters.
        ChatFailurePolicyCase(state: .cancelled, expected: .evictSilently),
        ChatFailurePolicyCase(state: .failed(.cancelled), expected: .evictSilently),
        // A re-download reaches BOTH of these; each gets a history lookup.
        ChatFailurePolicyCase(state: .failed(.alreadyDownloaded), expected: .recoverViaHistory),
        ChatFailurePolicyCase(
            state: .failed(.downloadFailed(detail: "ERROR: Postprocessing: Conversion failed!")),
            expected: .recoverViaHistory
        ),
        // Defensive: production rewrites this to the bare `.cancelled` before the seam.
        ChatFailurePolicyCase(state: .failed(.cancelledByEngine), expected: .evictWithNotice),
        // Every other real fault: the append expectation is abandoned out loud.
        ChatFailurePolicyCase(state: .failed(.invalidArguments), expected: .evictWithNotice),
        ChatFailurePolicyCase(state: .failed(.engineRestartRequired), expected: .evictWithNotice),
        ChatFailurePolicyCase(state: .failed(.destinationUnavailable), expected: .evictWithNotice),
        ChatFailurePolicyCase(state: .failed(.toolMissing), expected: .evictWithNotice),
        ChatFailurePolicyCase(state: .failed(.updateFailed(detail: nil)), expected: .evictWithNotice),
        ChatFailurePolicyCase(state: .failed(.unknown(code: 9)), expected: .evictWithNotice),
    ]

    /// The case name of `state`, through a switch that MUST stay exhaustive.
    static func tag(for state: DownloadState) -> String {
        switch state {
        case .queued: "queued"
        case .fetchingMetadata: "fetchingMetadata"
        case .downloading: "downloading"
        case .postProcessing: "postProcessing"
        case .finished: "finished"
        case .cancelled: "cancelled"
        case let .failed(error): "failed.\(tag(for: error))"
        }
    }

    /// The case name of `error`, through a switch that MUST stay exhaustive.
    static func tag(for error: DownloadError) -> String {
        switch error {
        case .downloadFailed: "downloadFailed"
        case .invalidArguments: "invalidArguments"
        case .engineRestartRequired: "engineRestartRequired"
        case .cancelled: "cancelled"
        case .cancelledByEngine: "cancelledByEngine"
        case .alreadyDownloaded: "alreadyDownloaded"
        case .destinationUnavailable: "destinationUnavailable"
        case .toolMissing: "toolMissing"
        case .updateFailed: "updateFailed"
        case .unknown: "unknown"
        }
    }

    /// Every tag the table must carry: the six non-`failed` states plus one per error.
    static let requiredTags: Set<String> = [
        "queued",
        "fetchingMetadata",
        "downloading",
        "postProcessing",
        "finished",
        "cancelled",
        "failed.downloadFailed",
        "failed.invalidArguments",
        "failed.engineRestartRequired",
        "failed.cancelled",
        "failed.cancelledByEngine",
        "failed.alreadyDownloaded",
        "failed.destinationUnavailable",
        "failed.toolMissing",
        "failed.updateFailed",
        "failed.unknown",
    ]
}

@Suite("Chat download failure policy")
struct ChatDownloadFailurePolicyTests {
    @Test("every state classifies exactly as the table says", arguments: ChatFailurePolicyCoverage.table)
    func classificationTable(entry: ChatFailurePolicyCase) {
        #expect(ChatDownloadFailurePolicy.classify(entry.state) == entry.expected)
    }

    /// The other half of the exhaustiveness lock: a case that compiles but was never
    /// added to the table above.
    @Test("the table covers every state case and every error case exactly once")
    func tableCoversEveryCase() {
        let tags = ChatFailurePolicyCoverage.table.map { ChatFailurePolicyCoverage.tag(for: $0.state) }
        #expect(Set(tags) == ChatFailurePolicyCoverage.requiredTags)
        #expect(tags.count == ChatFailurePolicyCoverage.requiredTags.count)
    }

    /// `detail` is engine diagnostics, never a classification input.
    ///
    /// `exitOutcome` maps EVERY `ExitCode.downloadError` to `.downloadFailed` — network
    /// errors and 403s included — with whatever the last error line happened to be. If
    /// the diagnostic text steered the answer, a re-download whose stderr differed by one
    /// character would stop attempting recovery.
    @Test("downloadFailed recovers regardless of its engine diagnostics")
    func downloadFailedIgnoresDetail() {
        #expect(ChatDownloadFailurePolicy.classify(.failed(.downloadFailed(detail: nil))) == .recoverViaHistory)
        #expect(ChatDownloadFailurePolicy.classify(.failed(.downloadFailed(detail: ""))) == .recoverViaHistory)
        #expect(
            ChatDownloadFailurePolicy.classify(.failed(.downloadFailed(detail: "HTTP Error 403")))
                == .recoverViaHistory
        )
    }

    /// Post-processing reports a fraction and then reports `nil` again at `progress=end`.
    /// Both are mid-flight, and neither is a terminal state to act on.
    @Test("postProcessing is ignored with and without an ffmpeg sample")
    func postProcessingIgnoresFraction() {
        #expect(ChatDownloadFailurePolicy.classify(.postProcessing(fraction: nil)) == .ignore)
        #expect(ChatDownloadFailurePolicy.classify(.postProcessing(fraction: 0.42)) == .ignore)
    }

    /// The classifier is a pure function of the state: same input, same answer, always.
    @Test("classification is stable across repeated calls")
    func classificationIsPure() {
        for entry in ChatFailurePolicyCoverage.table {
            let first = ChatDownloadFailurePolicy.classify(entry.state)
            let second = ChatDownloadFailurePolicy.classify(entry.state)
            #expect(first == second)
        }
    }
}
