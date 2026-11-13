// LibraryChatBudget — the 4096-token context policy, as pure arithmetic.
//
// ── WHAT ACTUALLY COMPETES FOR THE WINDOW ─────────────────────────────────────
//
// A FoundationModels session has ONE budget — `SystemLanguageModel.contextSize`,
// 4096 on this SDK — and everything lives in it at once:
//
//   • the instructions, once;
//   • all five tool DEFINITIONS (name + description + argument schema), re-billed
//     on EVERY turn — which is the whole reason ``ToolProfile/onDevice`` publishes
//     five tools and not nine;
//   • every previous turn's prompt and response;
//   • every tool call and every tool RESULT, each bounded to 600 characters by
//     ``ToolProfile/onDeviceCharacterLimit``.
//
// A conversation therefore does not overflow because one message was large; it
// overflows because it kept going. So the policy is a running measurement with a
// recovery, not a per-message cap.
//
// ── TWO HALVES, BOTH REQUIRED ─────────────────────────────────────────────────
//
// PROACTIVE: before each send, estimate the transcript and condense once usage
// crosses ``condensationFraction`` of the window. Half, because the turn about to
// run has to fit its prompt, up to five tool round-trips and an answer — a
// threshold that only fired at 90% would fire during a turn it could no longer
// rescue.
//
// REACTIVE: `GenerationError.exceededContextWindowSize` still condenses and
// retries ONCE. The estimate below macOS 26.4 is a character heuristic and a
// heuristic can be wrong; a throw is ground truth. Neither half makes the other
// redundant.
//
// ── WHY "FIRST AND LAST" IS THE RIGHT CONDENSATION ────────────────────────────
//
// The FIRST entry is the session's `.instructions`, which carries the tool
// definitions — drop it and the rebuilt session has no tools and no grounding,
// which is a silent capability loss rather than a visible failure. The LAST entry
// is what the listener is looking at. Everything between them is recoverable by
// asking again; those two are not. Apple documents exactly this recovery shape.
//
// ── THE ESTIMATE IS A FALLBACK, NOT THE MEASUREMENT ───────────────────────────
//
// `SystemLanguageModel.tokenCount(for:)` is the real answer and the session uses
// it whenever it can — but it is `@available(macOS 26.4, iOS 26.4, *)` with NO
// back-deployment (verified in the local SDK; `contextSize`, by contrast, IS
// `@backDeployed(before: macOS 26.4)` and is therefore readable at macOS 26.0).
// Below 26.4 there is no tokenizer to ask, so ``estimatedTokens(forCharacters:)``
// approximates at four characters per token and DELIBERATELY rounds up: an
// over-estimate condenses early, an under-estimate overflows.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// The context-window arithmetic ``LibraryChatSession`` runs on.
///
/// Pure, floor-available and side-effect-free on purpose: the session's context
/// policy is the part most likely to be wrong, and this is the shape that lets a
/// test drive every branch of it without a model, a macOS 26 host, or Apple
/// Intelligence being enabled.
public enum LibraryChatBudget {
    /// Characters assumed to make one token when no tokenizer is reachable.
    ///
    /// Four is the conventional English ratio. Tool results are the bulk of this
    /// transcript and are dense, punctuated one-line rows — which tokenize WORSE
    /// than prose, so four characters per token under-counts them and the
    /// rounding-up below is not a rounding detail but the safety margin.
    public static let charactersPerToken = 4

    /// The window fraction at which the transcript is condensed before sending.
    /// See the file header for why this is a half and not a nine-tenths.
    public static let condensationFraction = 0.5

    /// The window size assumed when the real `contextSize` cannot be read.
    /// Matches what the macOS 26.5 SDK's back-deployed `contextSize` returns.
    public static let assumedContextSize = 4096

    /// Tokens `characters` are assumed to occupy, rounded UP.
    ///
    /// Never returns a negative count, and returns `0` only for an empty input —
    /// so a caller can compare it against a threshold without a special case for
    /// the first turn.
    public static func estimatedTokens(forCharacters characters: Int) -> Int {
        guard characters > 0 else { return 0 }
        return (characters + charactersPerToken - 1) / charactersPerToken
    }

    /// Tokens `entries` are assumed to occupy.
    public static func estimatedTokens(for entries: [ChatTranscriptEntry]) -> Int {
        estimatedTokens(forCharacters: entries.reduce(0) { $0 + $1.characterCount })
    }

    /// Whether the transcript should be condensed before the next send.
    ///
    /// - Parameters:
    ///   - usedTokens: The measured or estimated size of the transcript so far.
    ///   - contextSize: `SystemLanguageModel.contextSize`. A non-positive value is
    ///     treated as ``assumedContextSize`` rather than as "no limit" — a bad
    ///     reading must not disable the policy.
    public static func shouldCondense(usedTokens: Int, contextSize: Int) -> Bool {
        let window = contextSize > 0 ? contextSize : assumedContextSize
        return Double(usedTokens) >= Double(window) * condensationFraction
    }

    /// The indices a condensed transcript keeps, in transcript order.
    ///
    /// `[]` for an empty transcript, `[0]` for a single entry, and `[0, n - 1]`
    /// otherwise — the first (instructions + tool definitions) and the last (what
    /// the listener is looking at). Returning INDICES rather than entries is what
    /// keeps this function free of any FoundationModels type, and therefore
    /// testable; the session subscripts its own transcript with the result.
    public static func condensationSelection(entryCount: Int) -> [Int] {
        switch entryCount {
        case ..<1: []
        case 1: [0]
        default: [0, entryCount - 1]
        }
    }

    /// ``condensationSelection(entryCount:)`` applied to a floor-available
    /// transcript. The mirror of what the session does to the real one, so a test
    /// can assert the RESULT of a condensation and not merely its index maths.
    public static func condensed(_ entries: [ChatTranscriptEntry]) -> [ChatTranscriptEntry] {
        condensationSelection(entryCount: entries.count).map { entries[$0] }
    }
}
