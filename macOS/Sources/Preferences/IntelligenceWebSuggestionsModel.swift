// IntelligenceWebSuggestionsModel — what the web-suggestions section knows, minus
// the pixels.
//
// ── THE CONSENT GATE IS HERE, NOT IN THE VIEW ────────────────────────────────
//
// ``setEnabled(true)`` on an undisclosed feature OFFERS the disclosure and writes
// NOTHING; ``acceptConsent()`` is the only path that reaches
// `AppSettings.webSuggestionsConsented`. So the switch cannot stand in for the
// sheet, and a second control added to this section later inherits the refusal
// instead of having to remember to ask.
//
// ``IntelligenceExternalAccessSection`` holds the equivalent single-grant gate in a
// `Binding`'s setter, and that would have been the closer precedent by shape. It is
// NOT followed here for one reason: the claim this pane has to make — "declining
// leaves both records unwritten" — is a claim about a side effect that did not
// happen, and a `@State` in a view can only be asked that through an XCUITest. The
// MCP section moved its gate into a model for exactly this reason
// (``MCPServersSectionModel``'s header); this one carries two Keychain slots as
// well, so there is twice as much that only a model can be asked about.
//
// ── ENABLEMENT AND DISCLOSURE ARE SEPARATE RECORDS ───────────────────────────
//
// ``acceptConsent()`` writes both, in that order, and nothing else ever writes
// `webSuggestionsConsented`. Switching the feature back OFF deliberately leaves the
// disclosure recorded: the listener was told, and re-enabling later is not a second
// first time. `WebSuggestionsSettingsTests` pins the independence at the store; this
// file is where the only writer of one of them lives.
//
// ── THE KEYS ARE OPTIONAL, AND ARE NEVER READ BACK INTO THE FIELD ────────────
//
// Both tools work keyless; a key only raises the provider's rate limits. So a blank
// field means "not entered this time", NEVER "delete it" — removal is its own
// button. ``refreshStoredKeys()`` reads whether a secret EXISTS and never what it
// is, the same discipline ``IntelligenceConnectorConfigModel/prepare()`` applies:
// pre-filling a `SecureField` with a real key makes it copyable, screenshot-able and
// screen-shareable for no gain.
//
// Nothing here reaches the network. The two service names are Keychain ADDRESSES;
// the requests that use them are built inside `AIConnectorKit`, which is the only
// place a transport may exist (`scripts/check-ai-network-boundary.sh`).
import AIConnectorKit
import Foundation
import Observation

// MARK: - Key slots

/// One of the two OPTIONAL keys the web-suggestions path may use.
///
/// The raw value IS the connector id, so ``service`` is derived from the same
/// `ConnectorSecretService` namespace builder every other credential uses rather
/// than being a second copy of the address format.
enum WebSuggestionsKeySlot: String, CaseIterable, Identifiable {
    /// The search provider consulted for songs that are not in the library.
    case search = "web_search"
    /// The video service a suggested link is verified against.
    case video = "youtube"

    var id: String {
        rawValue
    }

    /// The Keychain namespace this slot's key lives in — the same one the tools
    /// read at call time, which is why a key pasted here works with no relaunch.
    var service: String {
        ConnectorSecretService.name(forConnectorID: rawValue)
    }
}

// MARK: - Disclosure

/// What the web-suggestions disclosure is about: the two services the feature would
/// contact, named.
///
/// The names are BRANDS — interpolated verbatim into localized templates, never
/// translated. `Identifiable` on the pair so `.sheet(item:)` re-presents if the
/// services a build talks to ever change; the sheet names them, so a stale identity
/// would leave a false statement on screen.
struct WebSuggestionsDisclosure: Identifiable, Equatable {
    let searchProviderName: String
    let videoProviderName: String

    var id: String {
        "\(searchProviderName)|\(videoProviderName)"
    }

    /// The pair this build actually contacts.
    static let live = WebSuggestionsDisclosure(
        searchProviderName: "Tavily",
        videoProviderName: "YouTube"
    )
}

// MARK: - Model

/// The web-suggestions section's state: the gated switch, the disclosure it can
/// raise, and the two optional keys.
@MainActor
@Observable
final class WebSuggestionsSectionModel {
    /// The disclosure currently on screen, or `nil`.
    var consenting: WebSuggestionsDisclosure?

    /// Set when a key could not be stored or removed — in practice a locked
    /// Keychain. Cleared by the next attempt, so it never outlives its cause.
    private(set) var didFailToStoreKey = false

    /// What has been typed, per slot. LOCAL: no store observes this, which is what
    /// keeps a Keychain write off every keystroke.
    private var drafts: [WebSuggestionsKeySlot: String] = [:]

    /// Which slots hold a stored key. Existence only — never the value.
    private var storedSlots: Set<WebSuggestionsKeySlot> = []

    private let settings: AppSettings
    private let secrets: any SecretStore

    init(settings: AppSettings, secrets: any SecretStore) {
        self.settings = settings
        self.secrets = secrets
    }

    /// Whether the whole section is live. Web suggestions are an assistant feature,
    /// so they are meaningless — and inert — while the master switch is off.
    var isSectionEnabled: Bool {
        settings.intelligenceEnabled
    }

    var isEnabled: Bool {
        settings.webSuggestionsEnabled
    }

    // MARK: Enablement

    /// Switching OFF is unconditional and immediate. Switching ON without the
    /// disclosure on file OFFERS it and writes nothing at all.
    func setEnabled(_ isOn: Bool) {
        guard isOn else {
            settings.webSuggestionsEnabled = false
            return
        }
        guard settings.webSuggestionsConsented else {
            consenting = .live
            return
        }
        settings.webSuggestionsEnabled = true
    }

    /// The single path from a disclosure to a grant. Records that the listener was
    /// told, then switches the feature on.
    func acceptConsent() {
        guard consenting != nil else { return }
        consenting = nil
        settings.webSuggestionsConsented = true
        settings.webSuggestionsEnabled = true
    }

    /// Declining writes nothing — not the disclosure record, not the switch.
    func declineConsent() {
        consenting = nil
    }

    // MARK: The two optional keys

    func draft(for slot: WebSuggestionsKeySlot) -> String {
        drafts[slot] ?? ""
    }

    func setDraft(_ value: String, for slot: WebSuggestionsKeySlot) {
        drafts[slot] = value
    }

    /// Whether a key is stored for `slot`. Never the key itself.
    func hasStoredKey(_ slot: WebSuggestionsKeySlot) -> Bool {
        storedSlots.contains(slot)
    }

    /// Whether typing has produced something worth committing. Whitespace is not a
    /// key, so a field holding only spaces offers nothing to save.
    func canSaveKey(for slot: WebSuggestionsKeySlot) -> Bool {
        !trimmedDraft(for: slot).isEmpty
    }

    /// Seeds both slots' "a key is saved" state. Reads EXISTENCE, never a value.
    func refreshStoredKeys() async {
        for slot in WebSuggestionsKeySlot.allCases {
            let stored = try? await secrets.get(service: slot.service, account: Self.account)
            if stored == nil {
                storedSlots.remove(slot)
            } else {
                storedSlots.insert(slot)
            }
        }
    }

    /// Commits what was typed into `slot`, and only when something was.
    ///
    /// An untouched field must not clear a key that is already stored: the field is
    /// never seeded from the Keychain, so "empty" means "not entered this time".
    /// Removing a key is what ``removeKey(for:)`` is for.
    func saveKey(for slot: WebSuggestionsKeySlot) async {
        let key = trimmedDraft(for: slot)
        guard !key.isEmpty else { return }
        didFailToStoreKey = false
        do {
            try await secrets.set(key, service: slot.service, account: Self.account)
            storedSlots.insert(slot)
            drafts[slot] = ""
        } catch {
            didFailToStoreKey = true
        }
    }

    /// Forgets `slot`'s key. A pasted key has to be revocable in the app that asked
    /// for it, without a trip through Keychain Access.
    ///
    /// `SecretStore.delete(service:account:)` is idempotent, so removing a key that
    /// was never pasted is not an error path.
    func removeKey(for slot: WebSuggestionsKeySlot) async {
        didFailToStoreKey = false
        do {
            try await secrets.delete(service: slot.service, account: Self.account)
            storedSlots.remove(slot)
            drafts[slot] = ""
        } catch {
            didFailToStoreKey = true
        }
    }

    private func trimmedDraft(for slot: WebSuggestionsKeySlot) -> String {
        draft(for: slot).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Keychain slot a plain API key uses inside its own service namespace.
    /// Named from the composition root's constant so this pane writes exactly where
    /// the tools read.
    private static var account: String {
        AppEnvironment.connectorAPIKeyAccount
    }
}

// MARK: - Live wiring

extension WebSuggestionsSectionModel {
    /// The model the section actually runs on: the real login Keychain.
    static func live(settings: AppSettings) -> WebSuggestionsSectionModel {
        WebSuggestionsSectionModel(settings: settings, secrets: KeychainSecretStore())
    }
}
