// LibraryChatRouting — which tier answers a chat turn, and what stands in the way.
//
// A PURE function over five inputs, deliberately separated from every view that
// consumes it. The gating matrix here is the whole of the product decision — which
// provider chats, when the library-browsing disclosure has to be shown, and what a
// listener is told when none of it is possible — and a matrix embedded in a `body`
// can only be checked by driving the app.
//
// ── THE SAME SELECTION THE INTELLIGENCE PANE PERSISTS ─────────────────────────
//
// `AppSettings.selectedConnectorID` is the ONE provider choice. Chat does not get a
// second picker: a listener who chose Ollama for playlist requests did not also mean
// to send their library browsing to Anthropic. `nil` is Apple Intelligence, exactly
// as in `IntelligenceProviderSection`.
//
// ── APPLE INTELLIGENCE IS EXEMPT FROM THE DISCLOSURE, BY CONSTRUCTION ─────────
//
// Nothing leaves the Mac on that route, so there is nothing to disclose. The consent
// gate is reachable only from the `.connector` branch — not by remembering to skip
// it, but because the FoundationModels branch never reads the consent record.
import AIConnectorKit
import Services

/// The tier that would answer.
enum LibraryChatRoute: Equatable, Hashable {
    /// On-device, through `LibraryChatSession`. The shipped default.
    case appleIntelligence
    /// A remote (or LAN) provider, through `ConnectorChatEngine`.
    ///
    /// `model` is carried rather than re-read at construction so the route a surface
    /// showed and the route it starts are provably the same value.
    case connector(id: String, displayName: String, model: String)
}

/// Whether a conversation can start, and why not when it cannot.
///
/// Exhaustive and repo-internal, so every switch over it carries NO `default:` — a
/// new state must be given copy in `LibraryChatEmptyState` before the shell compiles.
enum LibraryChatAvailability: Equatable {
    /// A conversation can start now.
    case ready(LibraryChatRoute)
    /// A cloud provider is selected and its library-browsing disclosure has not been
    /// accepted. The surface offers the sheet.
    case consentRequired(id: String, displayName: String)
    /// The disclosure was declined for this provider in this session. The one-shot
    /// request path is untouched — the original connector consent still covers it.
    case consentDeclined(id: String, displayName: String)
    /// The Intelligence master switch is off. Nothing AI exists at all.
    case intelligenceOff
    /// Apple Intelligence is selected and unreachable. There is no on-device chat, and
    /// the heuristic tier that still answers plain requests cannot hold a conversation.
    case appleIntelligenceUnavailable(AssistantUnavailableReason)
    /// A provider is selected that cannot call tools, so it cannot browse a library.
    case providerCannotChat(id: String, displayName: String)
    /// A provider is selected with its model left on Automatic. Every connector reads
    /// an absent model as `ConnectorFailure.unconfigured` and raises before any
    /// request, so a conversation could only ever fail — say so instead.
    case providerNeedsModel(id: String, displayName: String)

    /// The route, when there is one.
    var route: LibraryChatRoute? {
        if case let .ready(route) = self { return route }
        return nil
    }

    /// Whether a chat turn may be started.
    var isReady: Bool {
        route != nil
    }

    /// The provider whose disclosure the surface should offer, if any.
    var pendingConsent: (id: String, displayName: String)? {
        if case let .consentRequired(id, displayName) = self { return (id, displayName) }
        return nil
    }
}

/// The connector half of the routing inputs, resolved by the caller.
///
/// `supportsToolCalling` is decided by a CAST against `ToolCallingConnector` at the
/// composition root, never by a name list here: a connector that gains or loses the
/// conformance changes this answer with no edit to the matrix.
struct LibraryChatConnectorSelection: Equatable, Hashable {
    let id: String
    /// The provider's own brand name. Rendered `Text(verbatim:)`, never localized.
    let displayName: String
    let supportsToolCalling: Bool
    /// The listener's chosen model, or `nil` for the pane's Automatic entry.
    let model: String?
}

/// The matrix.
enum LibraryChatRouting {
    /// - Parameters:
    ///   - intelligenceEnabled: `AppSettings.intelligenceEnabled`, the master switch.
    ///   - selection: The RESOLVED connector selection, or `nil` for the shipped
    ///     Apple Intelligence default. Resolution (an id no build registers degrades
    ///     to `nil`) is the caller's, exactly as in `connectorRoute(settings:…)`.
    ///   - hasBrowsingConsent: Whether this connector's library-browsing disclosure
    ///     has been accepted. Never consulted on the Apple Intelligence route.
    ///   - isConsentDeclined: Whether the disclosure was declined for this provider
    ///     since the pane opened, so it is not re-offered on every send.
    ///   - appleIntelligence: `AssistantAvailabilityProbe.current(intelligenceEnabled:)`.
    static func availability(
        intelligenceEnabled: Bool,
        selection: LibraryChatConnectorSelection?,
        hasBrowsingConsent: Bool,
        isConsentDeclined: Bool,
        appleIntelligence: AssistantAvailability
    ) -> LibraryChatAvailability {
        guard intelligenceEnabled else { return .intelligenceOff }
        guard let selection else {
            switch appleIntelligence {
            case .available: return .ready(.appleIntelligence)
            case let .unavailable(reason): return .appleIntelligenceUnavailable(reason)
            }
        }
        guard selection.supportsToolCalling else {
            return .providerCannotChat(id: selection.id, displayName: selection.displayName)
        }
        // Before the disclosure, not after: asking someone to agree to a data
        // transfer that cannot succeed is worse than telling them what to fix.
        guard let model = selection.model, !model.isEmpty else {
            return .providerNeedsModel(id: selection.id, displayName: selection.displayName)
        }
        if isConsentDeclined {
            return .consentDeclined(id: selection.id, displayName: selection.displayName)
        }
        guard hasBrowsingConsent else {
            return .consentRequired(id: selection.id, displayName: selection.displayName)
        }
        return .ready(.connector(id: selection.id, displayName: selection.displayName, model: model))
    }
}
