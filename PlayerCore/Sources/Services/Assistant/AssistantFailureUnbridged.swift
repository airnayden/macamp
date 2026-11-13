// AssistantFailureUnbridged — the one FoundationModels error that arrives as a
// bare `NSError` instead of as `LanguageModelSession.GenerationError`.
//
// ── THE HOLE, RECORDED VERBATIM ──────────────────────────────────────────────
//
// Captured live on 2026-08-30 (host macOS 26.5.1, MacOSX26.5.sdk,
// FoundationModels 1.5.2) while a granted chat session was being measured:
//
//   NSError domain=FoundationModels.LanguageModelSession.GenerationError Code=-1
//     NSMultipleUnderlyingErrorsKey=( com.apple.tokengeneration Code=10 )
//
// The DOMAIN STRING names the SDK's own error type, but the value does NOT bridge
// to it: `error as? LanguageModelSession.GenerationError` is `nil`, so every
// `catch let error as LanguageModelSession.GenerationError` in this island misses
// it and the turn degrades to ``AssistantFailure/unknown`` — losing a reason the
// daemon had already computed. **Unbridged as of the macOS 26.5 SDK; re-check on
// an OS bump.**
//
// ── WHAT WAS MEASURED, AND WHAT IT RULES OUT ─────────────────────────────────
//
// Three facts, all measured on this host rather than read from documentation.
// Re-derive them before trusting this file against a newer SDK.
//
//  1. A GENUINE `GenerationError` bridges to an `NSError` carrying this exact
//     domain and a code that is the CASE INDEX — 0…8 for the nine shipped cases,
//     in declaration order (`exceededContextWindowSize` 0 … `refusal` 8). The
//     recorded `Code=-1` is therefore outside the bridgeable range: it is the
//     daemon's own "no specific case" sentinel, not a case this file could look up.
//  2. A REAL context overflow bridges CLEANLY. Both a 44,100-character prompt and
//     a transcript grown to 4,089 tokens threw a properly typed
//     `.exceededContextWindowSize` (code 0, `debugDescription` naming the token
//     counts). So this shape is NOT a context overflow, and mapping it to
//     ``AssistantFailure/contextExceeded`` would buy a retry that cannot help and
//     would then report the wrong reason twice.
//  3. `com.apple.tokengeneration` is the private `TokenGeneration.framework`'s own
//     domain — the model's token generator is what failed, underneath a request
//     the daemon had already accepted.
//
// ── WHY `throttled`, AND WHY NOT A NEW CASE ──────────────────────────────────
//
// ``AssistantFailure`` groups its cases "by what a caller can DO about them" — its
// own stated organizing rule. By that rule a transient, daemon-side generation
// failure belongs with ``AssistantFailure/throttled``: it is not fixable by
// changing the prompt (so not ``contextExceeded`` or ``malformedExchange``), the
// model is present and answered other turns (so not ``modelUnavailable``), nothing
// was declined (so not ``refused``), and the caller's correct response is the one
// `throttled` already prescribes — do not retry this turn, fall back a tier, try
// again later. A tenth taxonomy case would give three surfaces a new value to
// handle in order to prescribe exactly that same behaviour.
//
// ── FLOOR-AVAILABLE ON PURPOSE ───────────────────────────────────────────────
//
// The recognition is over STRINGS the daemon writes, so it needs no FoundationModels
// symbol and no `@available` gate — which is precisely what lets a hermetic test
// construct the exact `NSError` and drive the mapping on a machine with no Apple
// Intelligence at all.
//
// This file imports Foundation only (PlayerCore portability invariant).
import Foundation

extension AssistantFailure {
    /// The domain the FoundationModels daemon stamps on a generation failure it
    /// hands back as a bare `NSError`. It is the `String(reflecting:)` spelling of
    /// `LanguageModelSession.GenerationError`, which is why it reads like a type.
    static let unbridgedGenerationDomain = "FoundationModels.LanguageModelSession.GenerationError"

    /// The private `TokenGeneration.framework` domain that appears underneath it.
    static let tokenGenerationDomain = "com.apple.tokengeneration"

    /// Maps an error that reached a terminal `catch` — i.e. one the typed
    /// `GenerationError` catch above it already declined.
    ///
    /// Recognises ONLY the recorded constellation: this domain, carrying an
    /// underlying error from the token generator. Everything else is
    /// ``AssistantFailure/unknown``, unchanged.
    ///
    /// The observed `Code=-1` is deliberately NOT part of the predicate. It is an
    /// undocumented sentinel, and `GenerationError` is a RESILIENT system enum
    /// whose case order — and therefore whose bridged codes — may change in any OS
    /// update; keying on either number would make this silently stop matching. The
    /// two domains are the halves that carry meaning: the outer one says the daemon
    /// considered this a generation failure, the inner one says which component
    /// failed.
    static func mapping(unbridged error: any Error) -> AssistantFailure {
        let boxed = error as NSError
        guard boxed.domain == unbridgedGenerationDomain else { return .unknown }
        guard underlyingDomains(of: boxed).contains(tokenGenerationDomain) else { return .unknown }
        return .throttled
    }

    /// Both spellings Foundation uses, because the daemon picks one per error and a
    /// single-cause box is as plausible as the multi-cause one that was recorded.
    private static func underlyingDomains(of error: NSError) -> [String] {
        var domains: [String] = []
        if let single = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            domains.append(single.domain)
        }
        if let several = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error] {
            domains.append(contentsOf: several.map { ($0 as NSError).domain })
        }
        return domains
    }
}
