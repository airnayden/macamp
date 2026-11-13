// IntelligenceMCPServersModel — what the MCP section knows, minus the pixels.
//
// ── THE CONSENT GATE IS HERE, NOT IN THE VIEW ────────────────────────────────
//
// `setEnabled(true, …)` on an unconsented server OFFERS the disclosure and writes
// NOTHING; ``acceptConsent()`` is the only path that reaches
// `MCPServerConfigStore.recordConsent(forServerID:)`, and the store is in turn the
// only writer of the consent record — a descriptor whose `isConsented` flag says
// `true` is overwritten from that record on every decode (todo 12). So there are
// three doors and all three are locked from the same side, which is what makes
// "no server is enabled without stored consent" a property rather than a habit.
//
// A view could have held this logic in a `Binding`'s setter, the way
// ``IntelligenceExternalAccessSection`` holds the single external-access switch.
// It does not, for one reason: that switch is ONE grant with ONE consent record,
// while this is a grant per row, and the claim under test — "declining leaves the
// server disabled AND writes nothing" — is a claim about a side effect that did not
// happen. Only a model can be asked that without an XCUITest.
//
// ── THE DEADLINE IS INJECTED, NOT MEASURED ───────────────────────────────────
//
// ``probeTimeoutSeconds`` defaults to ``MCPClientManager/callTimeoutSeconds`` and is
// handed to the probe on every call. Production's probe enforces it (the manager's
// `bounded` race, which DISCONNECTS on expiry because the SDK's continuations do not
// answer cancellation); a test's probe merely records it. That split is deliberate:
// asserting a 30-second cap by waiting 30 seconds is not a test, it is a delay.
//
// ── NO TRANSPORT IS BUILT HERE ───────────────────────────────────────────────
//
// `scripts/check-ai-network-boundary.sh` scans every
// `macOS/Sources/Preferences/Intelligence*` file for `URLSession` and for process
// spawning. Neither appears in this file or in its live wiring: the child process
// belongs to `MCPProcessTransport` and the HTTP session to the pinned SDK, and this
// layer only names them. See ``IntelligenceMCPProbe``.
import AIConnectorKit
import AIConnectorMCP
import Foundation
import Observation

// MARK: - Status

/// What one configured server is doing, as far as this pane can tell.
enum MCPServerConnectionStatus: Equatable {
    /// Switched off, or switched on but never consented — either way, inert.
    case disabled
    /// Usable, but never contacted, so nothing is known about it.
    case untested
    case testing
    case connected(toolCount: Int)
    /// Did not answer. `diagnostic` is an ``MCPClientFailure/DiagnosticToken`` —
    /// a fixed English token for a developer, never a server-supplied string.
    case unreachable(diagnostic: String)
}

/// The result of one reachability probe.
enum MCPServerProbeOutcome: Equatable {
    case connected(toolCount: Int)
    case unreachable(diagnostic: String)
}

/// Connects to one server once and reports what it publishes.
///
/// A closure rather than a protocol, for the reason
/// ``IntelligenceConnectorConfigModel``'s `probe` is one: production has exactly one
/// implementation, and what a test needs to observe is the DEADLINE it was handed,
/// not a type it can conform.
///
/// - Parameters:
///   - descriptor: The server to reach. Carries credential NAMES only.
///   - secrets: Those names' values, resolved from the Keychain by the caller.
///   - timeout: Seconds the whole probe may take.
typealias MCPServerProbing = @Sendable (
    _ descriptor: MCPServerDescriptor,
    _ secrets: [String: String],
    _ timeout: TimeInterval
) async -> MCPServerProbeOutcome

// MARK: - Sheet requests

/// What the trust disclosure is about. `Identifiable` on the server id so
/// `.sheet(item:)` re-presents when a different row asks.
struct MCPServerConsentDisclosure: Identifiable, Equatable {
    let id: UUID
    let serverName: String
    /// The program a command server would start, or `nil` for an address server.
    /// Present so the sheet can name it instead of describing a category.
    let command: String?
}

/// A request to open the add/edit sheet. `existing == nil` means "add", and `id` is
/// then the identity the new server will be saved under.
struct MCPServerEditRequest: Identifiable, Equatable {
    let id: UUID
    let existing: MCPServerDescriptor?
}

// MARK: - Model

/// The MCP servers section's state: the list, each row's live status, and the two
/// sheets it can raise.
@MainActor
@Observable
final class MCPServersSectionModel {
    /// Seconds one connection test may take. Read from ``MCPClientManager`` so the
    /// caption and the enforcement can never disagree.
    let probeTimeoutSeconds: TimeInterval

    /// Set when a save or a removal could not settle both stores — in practice a
    /// locked Keychain. Cleared by the next attempt.
    private(set) var didFailToPersist = false

    /// The trust disclosure currently on screen, or `nil`.
    var consenting: MCPServerConsentDisclosure?

    /// The add/edit sheet currently on screen, or `nil`.
    var editing: MCPServerEditRequest?

    private let store: MCPServerConfigStore
    private let probe: MCPServerProbing
    private var statuses: [UUID: MCPServerConnectionStatus] = [:]

    init(
        store: MCPServerConfigStore,
        probe: @escaping MCPServerProbing,
        probeTimeoutSeconds: TimeInterval = MCPClientManager.callTimeoutSeconds
    ) {
        self.store = store
        self.probe = probe
        self.probeTimeoutSeconds = probeTimeoutSeconds
    }

    var servers: [MCPServerDescriptor] {
        store.servers
    }

    /// A probed answer always wins: a listener who tested a switched-off server has
    /// been told something true about it, and "Off" would throw that away.
    func status(for serverID: UUID) -> MCPServerConnectionStatus {
        if let probed = statuses[serverID] { return probed }
        guard store.server(id: serverID)?.isUsable == true else { return .disabled }
        return .untested
    }

    // MARK: Enablement

    /// Switching OFF is unconditional. Switching ON without consent on file OFFERS
    /// the disclosure and writes nothing at all.
    func setEnabled(_ isEnabled: Bool, forServerID serverID: UUID) {
        guard isEnabled else {
            store.setEnabled(false, forServerID: serverID)
            return
        }
        guard store.hasConsent(forServerID: serverID) else {
            consenting = disclosure(forServerID: serverID)
            return
        }
        store.setEnabled(true, forServerID: serverID)
    }

    /// The single path from a disclosure to a grant.
    func acceptConsent() {
        guard let pending = consenting else { return }
        consenting = nil
        store.recordConsent(forServerID: pending.id)
        store.setEnabled(true, forServerID: pending.id)
    }

    /// Declining writes nothing — not the consent record, not the switch.
    func declineConsent() {
        consenting = nil
    }

    // MARK: Editing

    func beginAdd() {
        editing = MCPServerEditRequest(id: UUID(), existing: nil)
    }

    func beginEdit(_ descriptor: MCPServerDescriptor) {
        editing = MCPServerEditRequest(id: descriptor.id, existing: descriptor)
    }

    /// Commits a described server and its credential values in one step — the store
    /// settles `UserDefaults` and the Keychain together or not at all.
    ///
    /// The row's remembered status is dropped: an edited endpoint is a different
    /// server as far as reachability goes, and reporting the old answer beside the
    /// new address would be a lie the listener has no way to spot.
    func save(_ descriptor: MCPServerDescriptor, secretValues: [String: String]) async {
        didFailToPersist = false
        do {
            try await store.save(descriptor, secretValues: secretValues)
            statuses[descriptor.id] = nil
        } catch {
            didFailToPersist = true
        }
    }

    func remove(serverID: UUID) async {
        didFailToPersist = false
        do {
            try await store.remove(serverID: serverID)
            statuses[serverID] = nil
        } catch {
            didFailToPersist = true
        }
    }

    // MARK: Testing

    /// Contacts one server under this model's deadline and publishes what came back.
    func test(serverID: UUID) async {
        guard let descriptor = store.server(id: serverID) else { return }
        statuses[serverID] = .testing
        let secrets = await (try? store.resolvedSecrets(for: descriptor)) ?? [:]
        switch await probe(descriptor, secrets, probeTimeoutSeconds) {
        case let .connected(toolCount):
            statuses[serverID] = .connected(toolCount: toolCount)
        case let .unreachable(diagnostic):
            statuses[serverID] = .unreachable(diagnostic: diagnostic)
        }
    }

    private func disclosure(forServerID serverID: UUID) -> MCPServerConsentDisclosure? {
        guard let descriptor = store.server(id: serverID) else { return nil }
        return MCPServerConsentDisclosure(
            id: descriptor.id,
            serverName: descriptor.name,
            command: descriptor.endpoint.command
        )
    }
}

// MARK: - Live wiring

extension MCPServersSectionModel {
    /// The model the section actually runs on: the real Keychain, and a probe that
    /// really connects.
    static func live(settings: AppSettings) -> MCPServersSectionModel {
        MCPServersSectionModel(
            store: MCPServerConfigStore(settings: settings, secrets: KeychainSecretStore()),
            probe: IntelligenceMCPProbe.live()
        )
    }
}

// MARK: - Endpoint reading

extension MCPServerDescriptor.Endpoint {
    /// The program a command server starts, or `nil` for an address server.
    var command: String? {
        guard case let .stdio(command, _, _) = self else { return nil }
        return command
    }

    /// The address an HTTP server answers at, or `nil` for a command server.
    var address: URL? {
        guard case let .streamableHTTP(url, _) = self else { return nil }
        return url
    }
}
