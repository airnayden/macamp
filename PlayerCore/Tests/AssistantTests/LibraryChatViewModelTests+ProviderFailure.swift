// LibraryChatViewModelTests+ProviderFailure — a provider-side reason crossing into
// the transcript intact.
//
// ── WHY AN EXTENSION AND NOT A SIBLING SUITE ─────────────────────────────────
//
// Same reason `+Enrichment` is one: the lane that gates this seam is
// `swift test --filter LibraryChatViewModelTests`, and a filter matches the suite
// TYPE name, so a sibling suite under any other name would compile, pass locally,
// and never run in the lane meant to gate it. The extension is reached by the
// existing filter and keeps the parent file under `type_body_length`.
//
// ── WHAT THESE CASES ACTUALLY PIN ────────────────────────────────────────────
//
// `failure(for:)` collapses anything it does not recognise onto `.answerFailed`, and
// that collapse WAS the bug: a throttle carrying a real 52532-second reset read as
// "try again", which is the one action guaranteed to fail. So each case throws a
// vocabulary the shell already speaks and asserts the token, the duration and the
// status code survive — including a token this build has never heard of, which must
// cross whole rather than be filtered into the same shrug.
import Foundation
import Services
import Testing
import ViewModels

extension LibraryChatViewModelTests {
    @Test("a tier that already speaks this vocabulary is trusted, token and duration intact")
    func aThrownProviderFailureCrossesIntact() async {
        // The whole point of the token: a shell that KNOWS why the provider refused
        // says so, and this module carries the answer without learning what a
        // connector is. Collapsing it to `.answerFailed` here is the bug.
        let thrown = LibraryChatProviderFailure(
            reason: LibraryChatProviderFailure.Reason.rateLimited,
            retryAfter: 52532
        )
        let model = LibraryChatViewModel(makeEngine: {
            .success(LibraryChatEngine(prewarm: {}, send: { _ in throw LibraryChatFailure.providerFailed(thrown) }))
        })
        await model.send("hello")

        #expect(model.messages.last?.failure == .providerFailed(thrown))
        guard case let .providerFailed(carried) = model.messages.last?.failure else {
            Issue.record("the provider failure did not reach the transcript")
            return
        }
        #expect(carried.reason == "rate-limited")
        #expect(carried.retryAfter == 52532)
        #expect(carried.statusCode == nil)
    }

    @Test("an unrecognised token still crosses — the closed vocabulary lives in the shell, not here")
    func anUnknownProviderTokenCrossesUnchanged() async {
        // A token this build has never heard of is DATA, not an error: it travels
        // whole, and the surface degrades it to the generic sentence. Filtering it
        // out here would make a future token unrenderable rather than merely vague.
        let future = LibraryChatProviderFailure(reason: "quota-exhausted-in-a-later-build")
        let model = LibraryChatViewModel(makeEngine: {
            .success(LibraryChatEngine(prewarm: {}, send: { _ in throw LibraryChatFailure.providerFailed(future) }))
        })
        await model.send("hello")
        #expect(model.messages.last?.failure == .providerFailed(future))
    }

    @Test("an HTTP status crosses as a number, and the taxonomy carries no response body")
    func aThrownHTTPStatusCarriesTheCodeOnly() async {
        let status = LibraryChatProviderFailure(
            reason: LibraryChatProviderFailure.Reason.httpStatus,
            statusCode: 503
        )
        let model = LibraryChatViewModel(makeEngine: {
            .success(LibraryChatEngine(prewarm: {}, send: { _ in throw LibraryChatFailure.providerFailed(status) }))
        })
        await model.send("hello")

        guard case let .providerFailed(carried) = model.messages.last?.failure else {
            Issue.record("the provider failure did not reach the transcript")
            return
        }
        #expect(carried.statusCode == 503)
        #expect(carried.retryAfter == nil)
    }
}
