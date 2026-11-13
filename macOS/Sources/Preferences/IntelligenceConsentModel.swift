// IntelligenceConsentModel — what a remote provider receives, and who has agreed to it.
//
// ── WHY THE NUMBERS ARE READ AND NEVER WRITTEN DOWN ────────────────────────────
//
// ``ConnectorPayloadBudget`` (AIConnectorBridge) is the ONE definition of what may
// leave this Mac, and ``ConnectorPromptBuilder`` is the one enforcement of it. The
// consent sheet is the third party to that promise: it tells the listener the caps
// before the first request goes out. A literal copied into the copy would drift
// from the enforcement the day the budget changes — and the copy the listener read
// is the one that matters. So ``IntelligenceConsentDisclosure`` is the only type in
// the shell that names the budget, and it forwards rather than restates it.
//
// ── CONSENT IS PER CONNECTOR, AND IS NOT A SECRET ──────────────────────────────
//
// Accepting what an Ollama server on the LAN receives says nothing about what
// Anthropic would, so the record is keyed by connector id. It carries no credential
// and no listener data, which is exactly why it belongs in `AppSettings` next to
// the rest of the non-secret connector routing rather than in the Keychain.
import AIConnectorBridge
import Foundation

/// Records which connectors the listener has seen a payload disclosure for.
///
/// A protocol so the config model can be driven by a counting fake: the claim under
/// test is that an unconsented save writes NOTHING, and a negative claim about
/// writes cannot be checked from the end state.
@MainActor
protocol IntelligenceConnectorConsentStoring: AnyObject {
    /// Whether `connectorID`'s disclosure has already been accepted.
    func hasConsented(toConnectorID connectorID: String) -> Bool

    /// Records that `connectorID`'s disclosure was accepted. Idempotent.
    func recordConsent(forConnectorID connectorID: String)
}

/// The macOS witness: consent lives beside the rest of the connector routing.
extension AppSettings: IntelligenceConnectorConsentStoring {
    func hasConsented(toConnectorID connectorID: String) -> Bool {
        consentedConnectorIDs.contains(connectorID)
    }

    func recordConsent(forConnectorID connectorID: String) {
        consentedConnectorIDs.insert(connectorID)
    }
}

/// One connector's payload disclosure: who receives it, and exactly how much.
///
/// `Identifiable` on the connector id so `.sheet(item:)` drives presentation
/// directly — the same identity the accessibility identifiers are built from.
struct IntelligenceConsentDisclosure: Identifiable, Equatable {
    /// The connector's stable machine id.
    let id: String
    /// The provider's own name. A BRAND: rendered verbatim, never localized.
    let displayName: String

    /// Longest listener request that may leave the device.
    var requestCharacters: Int {
        ConnectorPayloadBudget.maxRequestCharacters
    }

    /// Genres offered to the provider as the answer vocabulary.
    var genres: Int {
        ConnectorPayloadBudget.maxGenres
    }

    /// Most-played artists offered as "more like this" hints.
    var artists: Int {
        ConnectorPayloadBudget.maxArtists
    }

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    /// The disclosure for the connector a setup sheet is about.
    init(configuration: IntelligenceConnectorConfiguration) {
        self.init(id: configuration.id, displayName: configuration.displayName)
    }
}
