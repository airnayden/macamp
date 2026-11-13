// LibraryChatFailureCopy — the sentence a listener reads when a turn fails.
//
// ── ONE SHRUG WAS THE BUG ────────────────────────────────────────────────────
//
// Every failed turn used to render `failureAnswerFailed` — "couldn't answer that,
// try again" — including the two that a listener can actually do something about.
// Measured 2026-09-06: both subscription providers refused with a spent quota
// (`ConnectorFailure.rateLimited`, ChatGPT's carrying a real 52532-second reset),
// and the surface said "try again", which is the one action guaranteed to fail. An
// expired sign-in reads the same way, and its fix is two clicks away in Preferences.
// So the classes a listener can act on get their own sentence, and only those.
//
// ── THE TOKEN IS MACHINERY; THIS FILE IS THE ONLY PLACE IT IS READ ───────────
//
// `LibraryChatProviderFailure.reason` is a stable machine token, never copy — the
// same discipline as `ConnectorFailure.DiagnosticToken` and the registry's
// `disabled(reason:)`, both of which are rendered by `PreferencesStrings` through
// exactly this shape. The `switch` over it therefore carries a `default:` on
// purpose: the vocabulary is a STRING vocabulary crossing a module boundary, so a
// token a later build introduces must degrade to the generic sentence rather than
// fail to compile or, far worse, print itself to a person.
//
// The `switch` over `LibraryChatFailure` itself has no `default:` for the opposite
// reason: that enum is repo-internal, so a new case must be given copy before the
// shell compiles.
//
// ── THE PROVIDER'S OWN SENTENCE GOES UNDERNEATH, NEVER INSTEAD ───────────────
//
// A typed sentence says what CLASS of thing went wrong and what to do about it;
// it cannot say that this particular request asked for 8192 tokens against a
// 4096 ceiling. `LibraryChatProviderFailure.detail` carries the provider's own
// `error.message` for exactly that, already sanitized and bounded by the
// connector — so this file composes rather than chooses. The typed copy stays
// first and stays localized; the detail is appended, because it is the provider's
// English and no catalog will ever translate it. A token this build does not know
// still degrades to the generic sentence, and still shows the detail when there is
// one: an unrecognised class is precisely when the provider's own words help most.
import Foundation
import Services
import ViewModels

enum LibraryChatFailureCopy {
    static func message(for failure: LibraryChatFailure) -> LocalizedStringResource {
        switch failure {
        case let .unavailable(reason): reason.message
        case .consentRequired: LibraryChatStrings.failureConsentRequired
        case let .providerFailed(provider):
            composed(providerMessage(provider), detail: provider.detail)
        case .answerFailed: LibraryChatStrings.failureAnswerFailed
        }
    }

    /// The typed sentence alone, or the same sentence with the provider's own words
    /// beneath it.
    ///
    /// A blank detail is treated as absent: a provider that answers with an empty
    /// `error.message` would otherwise add a trailing newline and nothing else.
    static func composed(
        _ typed: LocalizedStringResource,
        detail: String?
    ) -> LocalizedStringResource {
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false else { return typed }
        return LibraryChatStrings.failureWithDetail(String(localized: typed), detail: trimmed)
    }

    static func providerMessage(_ provider: LibraryChatProviderFailure) -> LocalizedStringResource {
        switch provider.reason {
        case LibraryChatProviderFailure.Reason.rateLimited: rateLimitedMessage(provider.retryAfter)
        case LibraryChatProviderFailure.Reason.authExpired: LibraryChatStrings.failureAuthExpired
        case LibraryChatProviderFailure.Reason.unreachable: LibraryChatStrings.failureUnreachable
        case LibraryChatProviderFailure.Reason.timeout: LibraryChatStrings.failureTimeout
        case LibraryChatProviderFailure.Reason.httpStatus: httpStatusMessage(provider.statusCode)
        case LibraryChatProviderFailure.Reason.truncated: LibraryChatStrings.failureTruncated
        default: LibraryChatStrings.failureAnswerFailed
        }
    }

    /// A wait a listener can plan around, or the plain sentence when the provider
    /// stated none. A non-positive duration is treated as absent: "try again in 0
    /// seconds" is worse than saying nothing about time at all.
    static func rateLimitedMessage(_ retryAfter: TimeInterval?) -> LocalizedStringResource {
        guard let retryAfter, retryAfter > 0 else { return LibraryChatStrings.failureRateLimited }
        return LibraryChatStrings.failureRateLimitedRetry(after: formattedWait(retryAfter))
    }

    /// The code alone. A status with no code cannot be phrased and degrades to the
    /// generic sentence rather than rendering an empty pair of brackets.
    static func httpStatusMessage(_ statusCode: Int?) -> LocalizedStringResource {
        guard let statusCode else { return LibraryChatStrings.failureAnswerFailed }
        return LibraryChatStrings.failureHTTPStatus(code: statusCode)
    }

    /// Foundation's own units style, so "14.59 hours" reads as "15 hours" in every
    /// locale without this file owning a single division. One unit only: the answer
    /// to "when can I ask again" is a rough horizon, not a countdown.
    static func formattedWait(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1)
        )
    }
}
