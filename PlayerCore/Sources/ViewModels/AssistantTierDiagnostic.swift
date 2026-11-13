// AssistantTierDiagnostic — WHICH tier of the assistant ladder failed, and how.
//
// ``AssistantViewModel/lastError`` answers "why is there no proposal". This answers
// the different, quieter question the listener also has a right to: "why did the
// provider I selected not answer this one?" A ladder that silently degrades from a
// paid connector to the local heuristic tier is CORRECT behaviour — it is what makes
// the feature work on a Mac with no Apple Intelligence and no network — but a
// degradation nobody is told about is indistinguishable from a broken setting.
//
// ── WHY IT IS SEPARATE FROM `lastError` ────────────────────────────────────────
//
// The two are orthogonal, and both can be set at once:
//
//   proposal produced + diagnostic set   the ladder fell through; the listener got
//                                        a playlist, just not from their provider.
//   no proposal + diagnostic set         the fall-through ALSO ended in nothing, so
//                                        the diagnostic explains the failure better
//                                        than `lastError` alone can.
//   no proposal + no diagnostic          an honest "nothing matched".
//
// Folding the tier failure into `lastError` would force a choice between reporting
// the provider problem and reporting the outcome; the UI needs both.
//
// ── WHY IT CARRIES NO PROVIDER IDENTITY ────────────────────────────────────────
//
// PlayerCore must not know that `AIConnectorKit` exists (the dependency direction is
// kit → PlayerCore, and it stays that way). The diagnostic therefore names the TIER,
// not the vendor; a shell that wants to name the selected provider already owns that
// setting and can compose the sentence itself.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit (PlayerCore
// portability invariant).
import Foundation

/// Why the tier the listener selected did not produce the last request's spec.
///
/// Repo-internal, so every switch over it must be exhaustive with no `default:`.
public enum AssistantTierDiagnostic: Sendable, Equatable {
    /// A connector is configured, but its OWN readiness predicate said no — the
    /// endpoint is unreachable, the key is missing, or the session is signed out.
    /// The ladder never sent the request.
    case connectorUnavailable
    /// The connector was asked and did not answer inside
    /// ``AssistantBackendStack/connectorDeadlineSeconds``. The parse was cancelled
    /// and abandoned; the lower tiers answered instead.
    case connectorTimedOut
    /// The connector was asked and threw. `reason` is a diagnostic string, NEVER
    /// shown verbatim to the listener — the shell renders its own localized copy.
    case connectorFailed(reason: String)
    /// The on-device FoundationModels tier threw. Same rule for `reason`.
    case modelFailed(reason: String)

    /// `true` for the three connector cases — the ones a "your provider didn't
    /// answer" notice is about. The on-device tier failing is a MacAMP problem, not
    /// a provider problem, so the shell words it differently.
    public var isConnectorTier: Bool {
        switch self {
        case .connectorUnavailable, .connectorTimedOut, .connectorFailed:
            true
        case .modelFailed:
            false
        }
    }
}
