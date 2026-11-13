// IntelligenceConnectorConfigModel — one connector's credential, edited locally, committed once.
//
// ── WHY COMMIT-ON-SUBMIT IS A REQUIREMENT, NOT A PREFERENCE ────────────────────
//
// `AppSettings` writes THROUGH in `didSet`, and `AppEnvironment`'s widened
// `withObservationTracking` reads `selectedConnectorID`, `selectedConnectorModels`
// and `ollamaHost` — so every one of those writes tears down and rebuilds the whole
// assistant graph. A `TextField` bound straight at `settings.ollamaHost` would do
// that ONCE PER KEYSTROKE: twenty rebuilds to type a host, each racing the last.
// The draft therefore lives here, in a property NOTHING observes but the sheet, and
// reaches the stores exactly once — in ``save()``.
//
// The same rule protects the Keychain: a `SecureField` bound at a `SecretStore`
// would perform a `SecItemUpdate` per character.
//
// ── THE KEY FIELD IS NEVER SEEDED FROM THE KEYCHAIN ────────────────────────────
//
// ``prepare()`` reads whether a secret EXISTS and never what it is. Pre-filling a
// `SecureField` with a real key would defeat the field: the value becomes
// copyable, screenshot-able and screen-shareable for no gain, since a listener who
// wants to keep the stored key simply does not type. The "a key is already saved"
// caption carries the only fact they need.
//
// ── THE CONSENT GATE LIVES AT THE COMMIT POINT, NOT IN THE VIEW ────────────────
//
// ``save()`` is the SINGLE commit point — there is no other path from this sheet to
// either store — so that is where the connect-time disclosure is enforced: an
// unconsented remote provider returns before the first write and both stores are
// untouched. The sheet PRESENTS the disclosure, but a second Save path written
// later inherits the refusal instead of having to remember to ask.
//
// Whether consent is required at all is decided by ``isLocalOnly``, computed from
// the same draft the commit is about to write: a loopback address sends nothing
// over a network, so it is never asked.
import AIConnectorBridge
import AIConnectorKit
import Foundation
import Observation

/// Which credential a connector needs, reduced to the ONE field the sheet shows.
///
/// Derived from ``AuthDescriptor`` rather than from a connector id, so a provider
/// added later gets the right field with no edit here. `subscription` has no
/// typeable credential at all — it is a sign-in flow — so it maps to nothing and
/// the provider section offers no setup sheet for it.
enum IntelligenceConnectorCredential: Equatable {
    /// A base address the listener types; the provider needs no secret.
    case host
    /// A secret pasted once and kept in the Keychain.
    case apiKey

    init?(_ descriptor: AuthDescriptor) {
        switch descriptor {
        case .none: self = .host
        case .apiKey: self = .apiKey
        case .subscription: return nil
        }
    }
}

/// The one connector a setup sheet is about.
///
/// `Identifiable` on the connector id so `.sheet(item:)` drives presentation
/// directly: the identity that decides which sheet is up is the same identity the
/// accessibility identifiers and the Keychain namespace are built from.
struct IntelligenceConnectorConfiguration: Identifiable, Equatable {
    /// The connector's stable machine id — also the `<id>` in every
    /// `intelligence.connectorConfig.<id>.*` accessibility identifier.
    let id: String
    /// The provider's own name. A BRAND: rendered verbatim, never localized.
    let displayName: String
    let credential: IntelligenceConnectorCredential

    init(id: String, displayName: String, credential: IntelligenceConnectorCredential) {
        self.id = id
        self.displayName = displayName
        self.credential = credential
    }

    /// `nil` when this connector has no sheet — the subscription providers, whose
    /// credential is obtained by signing in rather than by typing.
    init?(descriptor: ConnectorDescriptor) {
        guard let credential = IntelligenceConnectorCredential(descriptor.authDescriptor) else { return nil }
        self.init(id: descriptor.id, displayName: descriptor.displayName, credential: credential)
    }
}

/// The setup sheet's state: what has been typed, what the last check said, and the
/// two commits — save and remove — that are the only writes it performs.
@Observable
@MainActor
final class IntelligenceConnectorConfigModel {
    /// The result of the sheet's own "does this work?" attempt.
    ///
    /// One stored value replaced whole, never a `isChecking` / `status` pair
    /// mutated in sequence — the same discipline ``IntelligenceProviderModel``
    /// applies to its selection, and for the same reason: a half-applied pair can
    /// render a spinner beside a finished answer.
    enum Validation: Equatable {
        case idle
        case checking
        /// A completed attempt, rendered through the SHARED
        /// `PreferencesStrings.connectorStatusMessage(_:)` mapping.
        case finished(ConnectorStatus)
    }

    let configuration: IntelligenceConnectorConfiguration

    /// What has been typed. LOCAL — no store observes this, which is the whole
    /// point of the type.
    var draft = ""

    /// The OPTIONAL second credential, for a connector that accepts one alongside
    /// ``draft`` — today only Ollama's Cloud key. Empty means "no key", which is a
    /// fully-configured state for a self-hosted server, not a gap.
    var secretDraft = ""

    private(set) var validation: Validation = .idle

    /// Whether a secret is already stored for this connector. Never the secret.
    private(set) var hasStoredSecret = false

    /// One object, two roles: the non-secret routing this sheet commits, and the
    /// per-connector consent record that decides whether it may. `AppSettings`
    /// witnesses both, and a test can count writes to either through one fake.
    private let settings: any AIConnectorSettingsProviding & IntelligenceConnectorConsentStoring
    private let secrets: any SecretStore

    /// Checks a DRAFT credential — the one being typed, not the one on disk — by
    /// building a throwaway connector and probing it. `@MainActor` rather than
    /// `@Sendable`: it reaches `AppEnvironment`'s main-actor helpers, and the
    /// provider round-trip happens inside the nonisolated `probe()` it awaits.
    ///
    /// Two arguments, always: the primary credential and the optional secret. A
    /// connector that has no second credential ignores the second one.
    private let probe: @MainActor (String, String) async -> ConnectorStatus

    init(
        configuration: IntelligenceConnectorConfiguration,
        settings: any AIConnectorSettingsProviding & IntelligenceConnectorConsentStoring,
        secrets: any SecretStore,
        probe: @escaping @MainActor (String, String) async -> ConnectorStatus
    ) {
        self.configuration = configuration
        self.settings = settings
        self.secrets = secrets
        self.probe = probe
    }

    /// The Keychain namespace this connector's secret lives in — the SAME one
    /// `AppEnvironment.makeConnectorRegistry(settings:)` reads at call time, which
    /// is why a key saved here works with no relaunch.
    var service: String {
        ConnectorSecretService.name(forConnectorID: configuration.id)
    }

    var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedSecretDraft: String {
        secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether this connector accepts an OPTIONAL key beside its address.
    ///
    /// True for the address-configured provider, because Ollama Cloud speaks the
    /// same native API as a self-hosted server and differs only by a bearer. It is
    /// deliberately NOT a new ``IntelligenceConnectorCredential`` case: the
    /// credential kind is derived from ``AuthDescriptor``, and the descriptor is
    /// still honestly ``AuthDescriptor/none(defaultHost:)`` — nothing is REQUIRED.
    var supportsOptionalAPIKey: Bool {
        configuration.credential == .host
    }

    /// Whether committing this draft would keep every request on this machine.
    ///
    /// True only for an address-configured provider whose address resolves to
    /// loopback — the ONE case that sends nothing over a network. Computed from the
    /// DRAFT, because that is what ``save()`` is about to write; the consent gate
    /// that consumes it must judge the address being committed, not the last one.
    var isLocalOnly: Bool {
        guard configuration.credential == .host else { return false }
        return Self.isLoopback(AppEnvironment.ollamaHost(trimmedDraft))
    }

    /// What this connector would send, and to whom — the sheet's disclosure copy.
    var disclosure: IntelligenceConsentDisclosure {
        IntelligenceConsentDisclosure(configuration: configuration)
    }

    /// Whether committing this draft still needs the listener to accept
    /// ``disclosure`` first.
    ///
    /// True exactly once per connector: a loopback address never asks (nothing
    /// leaves the machine), and an acceptance is remembered per connector id, so
    /// editing a key later does not re-interrogate someone who already agreed.
    var requiresConsent: Bool {
        !isLocalOnly && !settings.hasConsented(toConnectorID: configuration.id)
    }

    /// Whether ``save()`` would do anything. A blank address MEANS "the standard
    /// one" and is savable; a blank key is not a key.
    var canSave: Bool {
        switch configuration.credential {
        case .host: true
        case .apiKey: !trimmedDraft.isEmpty
        }
    }

    /// Whether there is anything to remove: a stored key, a typed address, or a
    /// selection pointing here.
    var canRemove: Bool {
        hasStoredSecret || settings.selectedConnectorID == configuration.id || storedHost != nil
    }

    /// Seeds the sheet. Reads whether a secret exists — never its value.
    func prepare() async {
        // Deliberately left empty in BOTH branches: see the file header. The
        // caption is what tells the listener a key is already saved.
        secretDraft = ""
        switch configuration.credential {
        case .host:
            draft = storedHost ?? ""
        case .apiKey:
            draft = ""
        }
        let stored = try? await secrets.get(service: service, account: Self.account)
        hasStoredSecret = stored != nil
    }

    /// Checks the DRAFT credential without saving it.
    ///
    /// Everything the attempt can say is already a `ConnectorStatus`, including a
    /// rejected key (`401`/`403` → ``ConnectorStatus/authExpired``), so the sheet
    /// needs no failure vocabulary of its own.
    ///
    /// The optional key is passed too, so "Test" against Ollama Cloud checks the
    /// key that is about to be SAVED rather than the one already on disk.
    func validate() async {
        let candidate = trimmedDraft
        let secret = trimmedSecretDraft
        validation = .checking
        let status = await probe(candidate, secret)
        validation = .finished(status)
    }

    /// The ONE commit. Performs exactly one `AppSettings` write, plus one
    /// `SecretStore` write when there is a secret to store — and NOTHING at all
    /// while ``requiresConsent`` holds.
    ///
    /// The two credential kinds write different things for the same reason: an
    /// address IS the configuration, while a key is only useful once the provider
    /// it belongs to is the one answering — so saving a key ACTIVATES it, and that
    /// selection write is the single settings mutation.
    func save() async {
        guard canSave else { return }
        // Returning here is what "Cancel aborts the save" means mechanically:
        // nothing below has run, so neither store has been touched.
        guard !requiresConsent else { return }
        switch configuration.credential {
        case .host:
            // Blank means "the provider's standard address", stored as absence so
            // `AppEnvironment.ollamaHost(_:)` resolves the connector's own default.
            settings.ollamaHost = trimmedDraft.isEmpty ? nil : trimmedDraft
            await saveOptionalKey()
        case .apiKey:
            try? await secrets.set(trimmedDraft, service: service, account: Self.account)
            hasStoredSecret = true
            draft = ""
            settings.selectedConnectorID = configuration.id
        }
    }

    /// Commits the OPTIONAL key beside an address, and only when one was typed.
    ///
    /// An untouched field must not clear a key that is already stored: the field is
    /// never seeded from the Keychain, so "empty" means "not entered this time",
    /// NOT "delete it". Removing a key is what ``remove()`` is for.
    private func saveOptionalKey() async {
        let key = trimmedSecretDraft
        guard key.isEmpty == false else { return }
        try? await secrets.set(key, service: service, account: Self.account)
        hasStoredSecret = true
        secretDraft = ""
    }

    /// Records that ``disclosure`` was accepted for this connector, unblocking
    /// ``save()``. The ONLY writer of consent state, and never called by ``save()``
    /// itself — an acceptance is something the listener does, not something a
    /// commit infers.
    func grantConsent() {
        settings.recordConsent(forConnectorID: configuration.id)
    }

    /// Forgets this connector: the Keychain entry, the typed address, and the
    /// selection when it points here.
    ///
    /// Clearing the selection is what makes removal honest — leaving it set would
    /// route every request at a provider whose credential was just deleted, which
    /// reads as a broken app rather than as a removal. `nil` is the shipped
    /// default: Apple Intelligence, on-device, zero network.
    ///
    /// `SecretStore.delete(service:account:)` is idempotent, so removing a
    /// never-configured connector is not an error path.
    func remove() async {
        try? await secrets.delete(service: service, account: Self.account)
        hasStoredSecret = false
        draft = ""
        secretDraft = ""
        validation = .idle
        if configuration.credential == .host {
            settings.ollamaHost = nil
        }
        if settings.selectedConnectorID == configuration.id {
            settings.selectedConnectorID = nil
        }
    }

    /// The Keychain slot every plain API key uses, inside its connector's own
    /// service namespace. Named from the composition root's constant so the sheet
    /// writes exactly where `connectorAPIKey(_:for:)` reads.
    private static var account: String {
        AppEnvironment.connectorAPIKeyAccount
    }

    /// Whether `url` addresses this machine. Names only — no DNS lookup, because a
    /// consent decision must not depend on the network it is deciding about.
    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// The persisted address, normalised so a whitespace-only entry reads as none.
    private var storedHost: String? {
        guard configuration.credential == .host,
              let stored = settings.ollamaHost?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty
        else { return nil }
        return stored
    }
}

// MARK: - Live wiring

extension IntelligenceConnectorConfigModel {
    /// The model the sheet actually runs on: the real Keychain, and a check that
    /// builds a throwaway connector from whatever is currently typed.
    static func live(
        configuration: IntelligenceConnectorConfiguration,
        settings: AppSettings
    ) -> IntelligenceConnectorConfigModel {
        IntelligenceConnectorConfigModel(
            configuration: configuration,
            settings: settings,
            secrets: KeychainSecretStore(),
            probe: draftProbe(configuration: configuration)
        )
    }

    /// Checks a credential that is not saved yet, by asking the composition root.
    ///
    /// The connector — and the transport under it — is built by
    /// `AppEnvironment.draftProbe(connectorID:draft:)` rather than here, because
    /// `scripts/check-ai-network-boundary.sh` scans every
    /// `macOS/Sources/Preferences/Intelligence*` file for transport construction:
    /// a pane reaches a provider only through a connector somebody else built.
    static func draftProbe(
        configuration: IntelligenceConnectorConfiguration
    ) -> @MainActor (String, String) async -> ConnectorStatus {
        let identifier = configuration.id
        return { @MainActor draft, secret in
            await AppEnvironment.draftProbe(connectorID: identifier, draft: draft, secret: secret)
        }
    }
}
