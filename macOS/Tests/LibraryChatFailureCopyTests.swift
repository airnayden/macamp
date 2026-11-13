// LibraryChatFailureCopyTests — what a listener actually READS when a conversation
// turn fails, and what they must never read.
//
// ── THE RENDERED SENTENCE IS COMPARED, NOT THE MAPPING FUNCTION ───────────────
//
// "A mapping exists" is the misleading-success shape this suite refuses: a switch
// that returns the same generic resource for four classes compiles, passes any
// "is non-nil" assertion, and reproduces the exact bug this work fixes — a rate
// limit and an expired sign-in reading as one shrug. So every case here resolves
// the resource to a STRING in a fixed locale and compares whole sentences against
// each other, which is the only assertion a collapsed mapping cannot satisfy.
//
// ── TOKENS ARE MACHINERY AND MUST NOT REACH A PERSON ─────────────────────────
//
// `ConnectorFailure` payloads are machine diagnostics by that file's own contract:
// `underlying` is a `DiagnosticToken`, `body` is a truncated response payload. Both
// are secret-adjacent and neither is copy. The leak assertions below drive every
// case through the real mapping and search the rendered sentence for the token, for
// the body, and for the raw retry-after seconds.
import AIConnectorKit
import AIConnectorKitOAuth
import Foundation
@testable import MacAMP
import Services
import Testing
import ViewModels

@Suite("Library chat failure copy")
@MainActor
struct LibraryChatFailureCopyTests {
    private static let english = Locale(identifier: "en")

    private static func rendered(_ failure: LibraryChatFailure) -> String {
        LibraryChatFailureCopy.message(for: failure).resolved(in: english)
    }

    private static func rendered(_ failure: ConnectorFailure) -> String {
        guard let chat = ConnectorChatFailureMapping.chatFailure(for: failure) else {
            return rendered(.answerFailed)
        }
        return rendered(chat)
    }

    // MARK: - The kit's taxonomy, decided case by case

    /// Every `ConnectorFailure`, so the table below cannot quietly go stale.
    private static let allConnectorFailures: [ConnectorFailure] = [
        .unconfigured,
        .unreachable(underlying: ConnectorFailure.DiagnosticToken.connectionRefused),
        .timeout,
        .httpStatus(503, body: "{\"error\":\"upstream exploded\"}", providerMessage: nil),
        .authExpired,
        .rateLimited(retryAfter: 52532),
        .malformedResponse,
        .truncated,
        .cancelled,
    ]

    /// EXHAUSTIVE, with no `default:` — a tenth kit case is a compile error here,
    /// exactly as it is at every other consumer of that taxonomy.
    private static func isTranslated(_ failure: ConnectorFailure) -> Bool {
        switch failure {
        case .unreachable, .timeout, .httpStatus, .authExpired, .rateLimited, .truncated: true
        case .unconfigured, .malformedResponse, .cancelled: false
        }
    }

    @Test("the six actionable kit failures cross into chat; the other three keep today's behaviour")
    func onlyActionableFailuresAreTranslated() {
        for failure in Self.allConnectorFailures {
            let mapped = ConnectorChatFailureMapping.chatFailure(for: failure)
            #expect((mapped != nil) == Self.isTranslated(failure), "\(failure) was decided the wrong way")
        }
    }

    @Test("a rate limit carries its own duration across the module boundary")
    func aRateLimitCarriesItsRetryAfter() {
        // The measured case: 52532 seconds of spent subscription quota, which is the
        // one number that turns "try again" into an answer.
        let mapped = ConnectorChatFailureMapping.chatFailure(for: .rateLimited(retryAfter: 52532))
        guard case let .providerFailed(provider)? = mapped else {
            Issue.record("a rate limit must become a provider failure")
            return
        }
        #expect(provider.reason == LibraryChatProviderFailure.Reason.rateLimited)
        #expect(provider.retryAfter == 52532)
    }

    @Test("an HTTP status carries its code and drops the response body")
    func anHTTPStatusCarriesTheCodeOnly() {
        let mapped = ConnectorChatFailureMapping.chatFailure(for: .httpStatus(
            503,
            body: "upstream exploded",
            providerMessage: nil
        ))
        guard case let .providerFailed(provider)? = mapped else {
            Issue.record("an HTTP status must become a provider failure")
            return
        }
        #expect(provider.reason == LibraryChatProviderFailure.Reason.httpStatus)
        #expect(provider.statusCode == 503)
    }

    // MARK: - Every class, its own sentence

    @Test("a rate limit, an expired sign-in, an unreachable host, a status code and a cut-off answer differ")
    func eachFailureClassReadsDifferently() {
        let sentences = [
            Self.rendered(ConnectorFailure.rateLimited(retryAfter: nil)),
            Self.rendered(ConnectorFailure.authExpired),
            Self.rendered(ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.hostNotFound)),
            Self.rendered(ConnectorFailure.timeout),
            Self.rendered(ConnectorFailure.httpStatus(503, body: nil, providerMessage: nil)),
            Self.rendered(ConnectorFailure.truncated),
            Self.rendered(LibraryChatFailure.answerFailed),
        ]
        #expect(Set(sentences).count == sentences.count, "two failure classes share one sentence: \(sentences)")
        #expect(sentences.allSatisfy { !$0.isEmpty })
    }

    // MARK: - The answer that stopped halfway

    @Test("a cut-off answer says it was cut off, and says what to do about it")
    func aTruncatedAnswerNamesItsOwnFix() {
        let sentence = Self.rendered(ConnectorFailure.truncated)
        #expect(sentence == "The answer was cut off. Ask for fewer items, or try again.")
        // The bug this replaces: truncation used to render the generic shrug,
        // whose only advice — "ask in a different way" — does not fix a list that
        // was simply too long.
        #expect(sentence != Self.rendered(LibraryChatFailure.answerFailed))
    }

    @Test("a cut-off answer crosses as its own token, carrying no numbers it does not have")
    func aTruncationCarriesNoNumbers() {
        guard case let .providerFailed(provider)? = ConnectorChatFailureMapping.chatFailure(for: .truncated) else {
            Issue.record("a cut-off answer must become a provider failure")
            return
        }
        #expect(provider.reason == LibraryChatProviderFailure.Reason.truncated)
        // Truncation arrives on an HTTP 200 with no error payload, so there is no
        // status to name and no provider sentence to quote.
        #expect(provider.statusCode == nil)
        #expect(provider.detail == nil)
        #expect(provider.retryAfter == nil)
    }

    @Test("the Cloudflare challenge reads as unreachable, never as an expired sign-in")
    func aBotMitigationChallengeReadsAsUnreachable() {
        // The two are indistinguishable by HTTP status and only one is fixed by
        // signing in again — see `ChatGPTConnector.validate`.
        let challenge = ConnectorFailure.unreachable(underlying: ChatGPTConnector.botMitigationToken)
        #expect(Self.rendered(challenge) == Self.rendered(ConnectorFailure.unreachable(
            underlying: ConnectorFailure.DiagnosticToken.networkUnavailable
        )))
        #expect(Self.rendered(challenge) != Self.rendered(ConnectorFailure.authExpired))
    }

    @Test("an expired sign-in points at the pane that can fix it")
    func anExpiredSignInPointsAtPreferences() {
        let sentence = Self.rendered(ConnectorFailure.authExpired)
        #expect(sentence.contains("Intelligence"))
        #expect(sentence != Self.rendered(LibraryChatFailure.answerFailed))
    }

    @Test("a status code is named; the response body never is")
    func aStatusCodeIsNamedAndTheBodyIsNot() {
        let secret = "upstream said Bearer sk-live-should-never-render"
        let sentence = Self.rendered(ConnectorFailure.httpStatus(503, body: secret, providerMessage: nil))
        #expect(sentence.contains("503"))
        #expect(!sentence.contains("Bearer"))
        #expect(!sentence.contains(secret))
    }

    // MARK: - The provider's own sentence, underneath MacAMP's

    /// The measured shape: a 400 whose `error.message` says what a status code
    /// cannot, which is the whole reason this field crosses the boundary.
    private static let providerSentence = "max_tokens: 8192 > 4096, which is the maximum allowed for this model"

    @Test("a provider's own explanation is shown beneath the typed sentence, not instead of it")
    func aProviderDetailIsAppendedBeneathTheTypedSentence() {
        let withDetail = Self.rendered(ConnectorFailure.httpStatus(
            400,
            body: "{\"error\":{\"message\":\"\(Self.providerSentence)\"}}",
            providerMessage: Self.providerSentence
        ))
        let withoutDetail = Self.rendered(ConnectorFailure.httpStatus(400, body: nil, providerMessage: nil))

        // The typed copy is not replaced — the code a listener can quote survives.
        #expect(withDetail.hasPrefix(withoutDetail))
        #expect(withDetail.contains("400"))
        #expect(withDetail.contains(Self.providerSentence))
        // A second line, so the untranslated provider English never runs into the
        // localized sentence as though it were part of it.
        #expect(withDetail == "\(withoutDetail)\n\(Self.providerSentence)")
    }

    @Test("no detail leaves the sentence exactly as it reads today")
    func noDetailLeavesTodaysSentenceUntouched() {
        let bare = LibraryChatProviderFailure(
            reason: LibraryChatProviderFailure.Reason.httpStatus,
            statusCode: 400
        )
        #expect(Self.rendered(.providerFailed(bare))
            == Self.rendered(ConnectorFailure.httpStatus(400, body: nil, providerMessage: nil)))
        #expect(LibraryChatFailureCopy.message(for: .providerFailed(bare)).key
            == LibraryChatStrings.failureHTTPStatus(code: 400).key)
    }

    @Test("a blank detail is treated as absent rather than as an empty second line")
    func aBlankDetailIsTreatedAsAbsent() {
        let plain = Self.rendered(ConnectorFailure.httpStatus(400, body: nil, providerMessage: nil))
        for blank in ["", "   ", "\n", " \n\t "] {
            let failure = LibraryChatProviderFailure(
                reason: LibraryChatProviderFailure.Reason.httpStatus,
                statusCode: 400,
                detail: blank
            )
            #expect(Self.rendered(.providerFailed(failure)) == plain, "a blank detail must not add a line")
        }
    }

    @Test("an unknown token still degrades to the generic sentence, and still shows the detail")
    func anUnknownTokenKeepsTheGenericSentenceAndShowsTheDetail() {
        // The open-vocabulary `default:` is unchanged — an unrecognised class is
        // exactly when the provider's own words are worth the most.
        let future = LibraryChatProviderFailure(
            reason: "quota-exhausted-in-a-later-build",
            detail: Self.providerSentence
        )
        let generic = Self.rendered(LibraryChatFailure.answerFailed)
        #expect(Self.rendered(.providerFailed(future)) == "\(generic)\n\(Self.providerSentence)")
    }

    @Test("every provider class can carry a detail, and none of them loses its own sentence")
    func everyProviderClassKeepsItsSentenceWhenADetailIsAttached() {
        let classes = [
            LibraryChatProviderFailure.Reason.rateLimited,
            LibraryChatProviderFailure.Reason.authExpired,
            LibraryChatProviderFailure.Reason.unreachable,
            LibraryChatProviderFailure.Reason.timeout,
            LibraryChatProviderFailure.Reason.httpStatus,
            LibraryChatProviderFailure.Reason.truncated,
        ]
        for reason in classes {
            let bare = LibraryChatProviderFailure(reason: reason, retryAfter: 3600, statusCode: 503)
            let detailed = LibraryChatProviderFailure(
                reason: reason,
                retryAfter: 3600,
                statusCode: 503,
                detail: Self.providerSentence
            )
            #expect(
                Self.rendered(.providerFailed(detailed))
                    == "\(Self.rendered(.providerFailed(bare)))\n\(Self.providerSentence)",
                "\(reason) lost its copy"
            )
        }
    }

    // MARK: - The duration a listener can act on

    @Test("a rate limit with a duration renders it, and one without says so plainly")
    func aRateLimitRendersItsDuration() {
        let withDuration = Self.rendered(ConnectorFailure.rateLimited(retryAfter: 3600))
        let withoutDuration = Self.rendered(ConnectorFailure.rateLimited(retryAfter: nil))

        #expect(withDuration != withoutDuration)
        // Foundation's own units style, not a hand-rolled "x / 3600" — asserted
        // through the human-readable form rather than through the formatter call.
        #expect(withDuration.contains("1 hour"))
        #expect(Self.rendered(ConnectorFailure.rateLimited(retryAfter: 120)).contains("2 minutes"))
    }

    @Test("the measured 52532-second quota reads as hours, never as raw seconds")
    func theMeasuredQuotaRendersAsHours() {
        let sentence = Self.rendered(ConnectorFailure.rateLimited(retryAfter: 52532))
        #expect(!sentence.contains("52532"))
        #expect(!sentence.contains("52532.0"))
        #expect(sentence.contains("hour"))
    }

    @Test("a nonsensical duration degrades to the plain sentence rather than rendering nonsense")
    func anImpossibleDurationDegrades() {
        // Malformed input: a provider that answers `Retry-After: 0`, or a negative
        // value that survived a future parser change.
        let plain = Self.rendered(ConnectorFailure.rateLimited(retryAfter: nil))
        #expect(Self.rendered(ConnectorFailure.rateLimited(retryAfter: 0)) == plain)
        #expect(Self.rendered(ConnectorFailure.rateLimited(retryAfter: -30)) == plain)
    }

    // MARK: - Malformed and future input

    @Test("a token this build has never heard of degrades to the generic sentence")
    func anUnknownTokenDegradesToGeneric() {
        let future = LibraryChatProviderFailure(reason: "quota-exhausted-in-a-later-build", retryAfter: 60)
        #expect(Self.rendered(.providerFailed(future)) == Self.rendered(LibraryChatFailure.answerFailed))

        let empty = LibraryChatProviderFailure(reason: "")
        #expect(Self.rendered(.providerFailed(empty)) == Self.rendered(LibraryChatFailure.answerFailed))
    }

    @Test("no machine token, diagnostic or raw payload reaches a rendered sentence")
    func noMachineTokenIsEverRendered() {
        let machinery = [
            "rate-limited", "auth-expired", "unreachable", "timeout", "http-status", "truncated",
            ConnectorFailure.DiagnosticToken.connectionRefused,
            ConnectorFailure.DiagnosticToken.hostNotFound,
            ConnectorFailure.DiagnosticToken.networkUnavailable,
            ConnectorFailure.DiagnosticToken.secureConnectionFailed,
            ConnectorFailure.DiagnosticToken.invalidResponse,
            ConnectorFailure.DiagnosticToken.transportFailure,
            ChatGPTConnector.botMitigationToken,
            "upstream exploded",
        ]
        for failure in Self.allConnectorFailures {
            let sentence = Self.rendered(failure)
            for token in machinery {
                #expect(!sentence.contains(token), "\(failure) rendered the machine token \(token)")
            }
        }
    }

    // MARK: - What must not have changed

    @Test("consent and availability copy is untouched by the provider vocabulary")
    func theOlderFailureCopyIsUnchanged() {
        #expect(LibraryChatFailureCopy.message(for: .consentRequired).key
            == LibraryChatStrings.failureConsentRequired.key)
        #expect(LibraryChatFailureCopy.message(for: .answerFailed).key
            == LibraryChatStrings.failureAnswerFailed.key)
        #expect(Self.rendered(LibraryChatFailure.consentRequired)
            != Self.rendered(LibraryChatFailure.answerFailed))
    }
}
