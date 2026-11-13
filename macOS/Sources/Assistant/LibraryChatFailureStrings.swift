// LibraryChatFailureStrings — every sentence the conversation surface says when a
// turn produced no answer.
//
// Split out of `LibraryChatStrings.swift` for one mechanical reason: `.swiftlint.yml`
// does not override `file_length`, so the 400-line ceiling applies and CI runs
// `--strict`. Same precedent as `ChatGPTResponseMapping.swift`. The constants keep
// their catalog keys and their `LibraryChatStrings.` call sites exactly.
//
// The provider sentences below exist because one shrug was the bug — see
// `LibraryChatFailureCopy` for the measured incident and for the token vocabulary
// that chooses between them.
import Foundation

extension LibraryChatStrings {
    static let failureAnswerFailed = LocalizedStringResource(
        "app.assistant.chat.failure.answer",
        defaultValue: "The assistant couldn't answer that. Try again, or ask in a different way.",
        comment: "Message shown on a conversation turn that produced no answer"
    )

    static let failureConsentRequired = LocalizedStringResource(
        "app.assistant.chat.failure.consent",
        defaultValue: "This provider needs your permission to browse your library before it can hold a conversation.",
        comment: "Message shown when a conversation turn was refused for want of the library-browsing agreement"
    )

    // MARK: Why the provider refused

    static let failureRateLimited = LocalizedStringResource(
        "app.assistant.chat.failure.rateLimited",
        defaultValue: "This provider is limiting requests right now. Try again shortly.",
        comment: "Message shown when a conversation turn was throttled and the provider stated no wait"
    )

    /// The same refusal, with the wait the provider stated.
    ///
    /// - Parameter wait: An already-formatted duration — see
    ///   ``LibraryChatFailureCopy/formattedWait(_:)``. Never a raw seconds count.
    static func failureRateLimitedRetry(after wait: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.failure.rateLimited.retry",
            defaultValue: "This provider is limiting requests. Try again in about \(wait).",
            comment: "Message shown when a conversation turn was throttled, naming how long until it resets"
        )
    }

    static let failureAuthExpired = LocalizedStringResource(
        "app.assistant.chat.failure.authExpired",
        defaultValue: """
        This provider rejected its saved sign-in. Sign in to it again in \
        Preferences ▸ Intelligence, then ask again.
        """,
        comment: "Message shown when a conversation turn failed because the provider's credential was rejected"
    )

    static let failureUnreachable = LocalizedStringResource(
        "app.assistant.chat.failure.unreachable",
        defaultValue: "This provider could not be reached. Check your connection, then ask again.",
        comment: "Message shown when a conversation turn failed because the provider could not be reached at all"
    )

    static let failureTimeout = LocalizedStringResource(
        "app.assistant.chat.failure.timeout",
        defaultValue: "This provider did not answer in time. Ask again, or try a shorter request.",
        comment: "Message shown when a conversation turn failed because a deadline elapsed before the provider replied"
    )

    /// The ask was too big for one answer, said without blaming the provider.
    ///
    /// "Ask for fewer items" is the action, and it is the whole reason this class
    /// is not folded into ``failureAnswerFailed``: a cut-off answer is the one
    /// failure where rephrasing the SIZE of the request — not its wording — is
    /// what works.
    static let failureTruncated = LocalizedStringResource(
        "app.assistant.chat.failure.truncated",
        defaultValue: "The answer was cut off. Ask for fewer items, or try again.",
        comment: "Message shown when a conversation turn stopped at the provider's own output limit"
    )

    /// The provider's HTTP status, and nothing else it sent.
    static func failureHTTPStatus(code: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.failure.http",
            defaultValue: "This provider answered with an error (\(code.formatted(.number.grouping(.never)))).",
            comment: "Message shown when a conversation turn failed on an unusable HTTP status, with the code"
        )
    }

    /// MacAMP's own sentence, with the provider's underneath it.
    ///
    /// A separate line rather than one paragraph: `detail` is the provider's
    /// English and stays untranslated whatever the listener's language, so running
    /// it into the localized sentence would read as a broken translation. Beneath
    /// it, it reads as a quote — which is what it is.
    ///
    /// - Parameters:
    ///   - message: An already-resolved MacAMP sentence — one of the constants
    ///     above, never raw text.
    ///   - detail: The provider's own explanation, already sanitized and bounded
    ///     by the connector that produced it.
    static func failureWithDetail(_ message: String, detail: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.failure.detail",
            defaultValue: "\(message)\n\(detail)",
            comment: "A conversation failure message, with the provider's own untranslated explanation beneath it"
        )
    }
}
