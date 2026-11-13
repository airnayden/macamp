// MCPExternalAccessTests — the switch, the disclosure, and the port.
//
// Binding and lifecycle claims use a real listener:
//
//   * An undisclosed server NEVER binds — proven by driving the real
//     `apply(settings:)` with consent withheld and finding no listener.
//   * A busy port is REPORTED, never worked around. The second server on the same
//     port must say so, because "no silent fallback" is the whole security posture
//     of the address the pane prints.
//   * Stopping frees the port, provably: the same port binds again straight after.
// Status propagation uses a controlled listener actor to deliver a post-startup
// failure independently of settings changes and to delay its notification.
import Foundation
@testable import MacAMP
import Persistence
import Services
import Testing
import ViewModels

@Suite("MCP external access", .serialized)
@MainActor
struct MCPExternalAccessTests {
    /// Ports chosen per test so a parallel run of a sibling suite cannot collide.
    private enum Port {
        static let lifecycle = 47311
        static let restart = 47312
        static let busy = 47313
        static let change = 47314
    }

    private static func settings(_ function: String) -> AppSettings {
        let name = "com.example.macamp.tests.mcpExternalAccess.\(function)"
        guard let store = UserDefaults(suiteName: name) else { return AppSettings(defaults: .standard) }
        store.removePersistentDomain(forName: name)
        return AppSettings(defaults: store)
    }

    private static func model() -> MCPExternalAccessModel {
        let environment = AppEnvironment.preview()
        let toolbox = AppEnvironment.makeExternalToolbox(
            database: environment.database,
            profileId: ProfileRecord.guestID,
            proposals: ProposalStore()
        )
        return MCPExternalAccessModel(toolbox: { toolbox })
    }

    // MARK: Defaults

    @Test("external access ships off, undisclosed, on the port the server defaults to")
    func theShippedStateIsOff() {
        let settings = Self.settings(#function)
        #expect(settings.externalAccessEnabled == false)
        #expect(settings.externalAccessConsented == false)
        #expect(settings.externalAccessPort == AppSettings.defaultExternalAccessPort)
        // One number, two owners — asserted rather than assumed.
        #expect(AppSettings.defaultExternalAccessPort == MCPLibraryServer.defaultPort)
    }

    @Test("a stored nonsense port reads back as the default rather than as an unbindable one")
    func anInvalidStoredPortDegrades() {
        let name = "com.example.macamp.tests.mcpExternalAccess.invalidPort"
        let store = UserDefaults(suiteName: name)
        store?.removePersistentDomain(forName: name)
        store?.set(0, forKey: "com.example.macamp.settings.ai.externalAccess.port")
        let settings = AppSettings(defaults: store ?? .standard)
        #expect(settings.externalAccessPort == AppSettings.defaultExternalAccessPort)
    }

    // MARK: Gating

    @Test("the switch alone does NOT bind — the disclosure has to have been accepted")
    func consentGatesTheBind() async {
        let settings = Self.settings(#function)
        settings.intelligenceEnabled = true
        settings.externalAccessEnabled = true
        settings.externalAccessConsented = false
        settings.externalAccessPort = Port.lifecycle

        let model = Self.model()
        model.apply(settings: settings)
        await model.settle()
        #expect(model.status == .stopped)
    }

    @Test("the master Intelligence switch gates it too — a proposal needs somewhere to be reviewed")
    func intelligenceGatesTheBind() async {
        let settings = Self.settings(#function)
        settings.intelligenceEnabled = false
        settings.externalAccessEnabled = true
        settings.externalAccessConsented = true
        settings.externalAccessPort = Port.lifecycle

        let model = Self.model()
        model.apply(settings: settings)
        await model.settle()
        #expect(model.status == .stopped)
    }

    @Test("with all three agreeing it binds the configured port, and stopping frees it")
    func itBindsAndReleases() async {
        let settings = Self.settings(#function)
        settings.intelligenceEnabled = true
        settings.externalAccessConsented = true
        settings.externalAccessEnabled = true
        settings.externalAccessPort = Port.lifecycle

        let model = Self.model()
        model.apply(settings: settings)
        await model.settle()
        #expect(model.status == .running(port: Port.lifecycle))

        settings.externalAccessEnabled = false
        model.apply(settings: settings)
        await model.settle()
        #expect(model.status == .stopped)

        // The port is genuinely free: a second server takes it straight away.
        let successor = Self.model()
        settings.externalAccessEnabled = true
        successor.apply(settings: settings)
        await successor.settle()
        #expect(successor.status == .running(port: Port.lifecycle))
        successor.shutDown()
        await successor.settle()
    }

    @Test("applying the same settings twice is idempotent — it does not rebind")
    func applyingTwiceIsIdempotent() async {
        let settings = Self.settings(#function)
        settings.intelligenceEnabled = true
        settings.externalAccessConsented = true
        settings.externalAccessEnabled = true
        settings.externalAccessPort = Port.restart

        let model = Self.model()
        model.apply(settings: settings)
        await model.settle()
        model.apply(settings: settings)
        await model.settle()
        #expect(model.status == .running(port: Port.restart))
        model.shutDown()
        await model.settle()
        #expect(model.status == .stopped)
    }

    @Test("changing the port moves the listener and releases the old one")
    func changingThePortRebinds() async {
        let settings = Self.settings(#function)
        settings.intelligenceEnabled = true
        settings.externalAccessConsented = true
        settings.externalAccessEnabled = true
        settings.externalAccessPort = Port.change

        let model = Self.model()
        model.apply(settings: settings)
        await model.settle()
        #expect(model.status == .running(port: Port.change))

        settings.externalAccessPort = Port.change + 1
        model.apply(settings: settings)
        await model.settle()
        #expect(model.status == .running(port: Port.change + 1))

        // The old port is free again.
        let squatter = Self.model()
        let other = Self.settings("\(#function).squatter")
        other.intelligenceEnabled = true
        other.externalAccessConsented = true
        other.externalAccessEnabled = true
        other.externalAccessPort = Port.change
        squatter.apply(settings: other)
        await squatter.settle()
        #expect(squatter.status == .running(port: Port.change))

        model.shutDown()
        squatter.shutDown()
        await model.settle()
        await squatter.settle()
    }

    @Test("a listener failure updates the model without another settings change")
    func listenerFailureUpdatesDisplayedStatus() async {
        let server = FailingMCPListener()
        let model = MCPExternalAccessModel(server: server, toolbox: { nil })
        let settings = Self.settings(#function)
        settings.intelligenceEnabled = true
        settings.externalAccessConsented = true
        settings.externalAccessEnabled = true
        settings.externalAccessPort = Port.restart
        model.apply(settings: settings)
        await model.settle()
        #expect(model.status == .running(port: Port.restart))

        await server.fail()
        #expect(await server.status == .failed(reason: "listener lost"))
        #expect(model.status == .failed(reason: "listener lost"))
        model.shutDown()
        await model.settle()
    }

    @Test("reapplying the same port after listener failure starts it again")
    func samePortCanRestartAfterListenerFailure() async {
        let server = FailingMCPListener()
        let model = MCPExternalAccessModel(server: server, toolbox: { nil })
        let settings = Self.settings(#function)
        settings.intelligenceEnabled = true
        settings.externalAccessConsented = true
        settings.externalAccessEnabled = true
        settings.externalAccessPort = Port.restart
        model.apply(settings: settings)
        await model.settle()
        #expect(await server.startCount == 1)

        await server.fail(deliverNotification: false)
        model.apply(settings: settings)
        await model.settle()
        #expect(await server.startCount == 2)
        #expect(await server.status == .running(port: Port.restart))
        #expect(model.status == .running(port: Port.restart))
        model.shutDown()
        await model.settle()
    }

    // MARK: The busy port

    @Test("a port already in use is REPORTED, never silently swapped for another")
    func aBusyPortIsReported() async {
        let first = Self.settings("\(#function).first")
        first.intelligenceEnabled = true
        first.externalAccessConsented = true
        first.externalAccessEnabled = true
        first.externalAccessPort = Port.busy

        let holder = Self.model()
        holder.apply(settings: first)
        await holder.settle()
        #expect(holder.status == .running(port: Port.busy))

        let second = Self.settings("\(#function).second")
        second.intelligenceEnabled = true
        second.externalAccessConsented = true
        second.externalAccessEnabled = true
        second.externalAccessPort = Port.busy

        let contender = Self.model()
        contender.apply(settings: second)
        await contender.settle()
        #expect(contender.status == .portUnavailable(port: Port.busy))
        // The port the listener was shown is the port that was tried, and only it.
        if case let .portUnavailable(port) = contender.status {
            #expect(port == second.externalAccessPort)
        }

        holder.shutDown()
        contender.shutDown()
        await holder.settle()
        await contender.settle()
    }

    // MARK: Consent record

    @Test("accepting the disclosure records a third, independent consent")
    func acceptingRecordsItsOwnRecord() {
        let settings = Self.settings(#function)
        #expect(settings.hasExternalAccessConsent == false)
        settings.recordExternalAccessConsent()
        #expect(settings.hasExternalAccessConsent)
        // Strictly independent of the two connector records — neither is widened.
        #expect(settings.consentedConnectorIDs.isEmpty)
        #expect(settings.libraryBrowsingConsentedConnectorIDs.isEmpty)
    }

    @Test("a connector's browsing consent does NOT admit an external program")
    func connectorConsentDoesNotImplyExternalAccess() {
        let settings = Self.settings(#function)
        settings.recordLibraryBrowsingConsent(forConnectorID: "anthropic")
        settings.consentedConnectorIDs.insert("anthropic")
        #expect(settings.hasExternalAccessConsent == false)
    }

    @Test("the disclosure states the tier's own caps and the port it is about to open")
    func theDisclosureForwardsItsNumbers() {
        let disclosure = ExternalAccessDisclosure(port: 46114)
        #expect(disclosure.rowsPerLookup == ToolProfile.external.rowLimit)
        #expect(disclosure.charactersPerLookup == ToolProfile.external.characterLimit)
        #expect(disclosure.id == 46114)
    }
}

private actor FailingMCPListener: MCPExternalAccessServing {
    private(set) var status: MCPServerStatus = .stopped
    private(set) var startCount = 0
    private var failureHandler: (@Sendable () async -> Void)?

    func setFailureHandler(_ handler: @escaping @Sendable () async -> Void) {
        failureHandler = handler
    }

    func start(port: Int, source _: MCPToolboxSource) async -> MCPServerStatus {
        startCount += 1
        status = .running(port: port)
        return status
    }

    func stop() async {
        status = .stopped
    }

    func fail(deliverNotification: Bool = true) async {
        status = .failed(reason: "listener lost")
        if deliverNotification { await failureHandler?() }
    }
}
