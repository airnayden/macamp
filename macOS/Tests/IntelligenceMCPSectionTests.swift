// IntelligenceMCPSectionTests — the claims the MCP section makes that a screenshot
// cannot check.
//
// ── THE CENTRAL CLAIM IS A NEGATIVE ──────────────────────────────────────────
//
// "No server is enabled without stored consent" is a claim about a write that did
// NOT happen. A rendering test cannot see it and an XCUITest can only see the
// switch's final position, which a bug that granted consent silently would leave
// looking identical. So the assertions below read `AppSettings` directly after each
// refusal: no enablement, no consent record, nothing.
//
// ── THE 30-SECOND CAP IS INJECTED, NOT WAITED OUT ────────────────────────────
//
// ``MCPServersSectionModel`` hands its deadline to the probe on every call, and the
// fake here RECORDS it. `unreachableProbeIsDeadlineCapped` therefore asserts the
// real bound — ``MCPClientManager/callTimeoutSeconds`` — and additionally asserts
// that the whole test finished in a fraction of it, which is what proves the value
// was injected rather than slept through. A server slower than its budget answers
// `.unreachable` by arithmetic.
//
// ── THE CATALOG HALF ─────────────────────────────────────────────────────────
//
// `everyMCPKeyIsInTheCatalogForEveryLocale` reads
// `macOS/Sources/Localizable.xcstrings` from disk rather than resolving resources,
// because "the key exists for `bg`" and "the key resolves to something" are
// different questions: a missing key resolves to its English `defaultValue` and
// looks fine. `bulgarianCopyIsNotEnglish` covers the other half — that the file the
// app actually ships from carries the translations.
import AIConnectorKit
import AIConnectorMCP
import Foundation
@testable import MacAMP
import Testing

/// Longer than any budget this pane hands out, so the fake's comparison always lands
/// on the timeout branch without anything actually taking that long.
///
/// File scope rather than a member of the suite: the suite is `@MainActor`, and a
/// `@Sendable` probe closure cannot read a main-actor-isolated static.
private let unresponsiveLatencySeconds: TimeInterval = 120

@Suite("Intelligence MCP servers section")
@MainActor
struct IntelligenceMCPSectionTests {
    // MARK: Listing

    @Test("the section lists what the store holds, transport and all")
    func modelListsConfiguredServers() async throws {
        let harness = Harness(named: "listing")
        try await harness.store.save(Self.stdioServer(named: "Alpha"))
        try await harness.store.save(Self.httpServer(named: "Beta"))

        #expect(harness.model.servers.map(\.name) == ["Alpha", "Beta"])
        #expect(harness.model.servers.first?.endpoint.command == "npx")
        #expect(harness.model.servers.last?.endpoint.address?.absoluteString == Self.httpAddress)
        // Nothing has been enabled or probed, so every row reads as inert.
        for server in harness.model.servers {
            #expect(harness.model.status(for: server.id) == .disabled)
        }
    }

    // MARK: The consent gate

    @Test("switching on without consent raises the disclosure and writes nothing")
    func enablingWithoutConsentRaisesTheSheet() async throws {
        let harness = Harness(named: "gate")
        let descriptor = Self.stdioServer(named: "Alpha")
        try await harness.store.save(descriptor)

        harness.model.setEnabled(true, forServerID: descriptor.id)

        let disclosure = try #require(harness.model.consenting)
        #expect(disclosure.id == descriptor.id)
        #expect(disclosure.serverName == "Alpha")
        // The sheet names the actual program, so the local-execution warning is
        // about something the listener can recognise.
        #expect(disclosure.command == "npx")
        harness.expectUntouched(descriptor.id)
    }

    @Test("declining leaves the server disabled and records no consent")
    func decliningWritesNothing() async throws {
        let harness = Harness(named: "decline")
        let descriptor = Self.stdioServer(named: "Alpha")
        try await harness.store.save(descriptor)

        harness.model.setEnabled(true, forServerID: descriptor.id)
        harness.model.declineConsent()

        #expect(harness.model.consenting == nil)
        harness.expectUntouched(descriptor.id)
        #expect(harness.model.status(for: descriptor.id) == .disabled)
    }

    @Test("an address server's disclosure names no local program")
    func addressServerDisclosureHasNoCommand() async throws {
        let harness = Harness(named: "addressGate")
        let descriptor = Self.httpServer(named: "Beta")
        try await harness.store.save(descriptor)

        harness.model.setEnabled(true, forServerID: descriptor.id)

        #expect(harness.model.consenting?.command == nil)
        harness.expectUntouched(descriptor.id)
    }

    // MARK: Reachability

    @Test("accepting the disclosure enables the server, which then reports its tools")
    func acceptedServerReportsConnectedWithToolCount() async throws {
        let recorder = ProbeRecorder()
        let harness = Harness(named: "connected", probe: Self.probe(recorder: recorder) { _ in
            .connected(toolCount: 4)
        })
        let descriptor = Self.stdioServer(named: "Alpha")
        try await harness.store.save(descriptor, secretValues: ["EXAMPLE_API_KEY": Self.secretValue])

        harness.model.setEnabled(true, forServerID: descriptor.id)
        harness.model.acceptConsent()

        #expect(harness.model.consenting == nil)
        #expect(harness.settings.hasMCPConsent(forServerID: descriptor.id))
        #expect(harness.settings.mcpServers.first?.isUsable == true)

        await harness.model.test(serverID: descriptor.id)

        #expect(harness.model.status(for: descriptor.id) == .connected(toolCount: 4))
        // The Keychain half really was resolved and handed over — a probe that got
        // an empty dictionary would still have reported "connected".
        let seen = await recorder.secrets
        #expect(seen.first?["EXAMPLE_API_KEY"] == Self.secretValue)
    }

    @Test("an unreachable server reports unreachable, under an injected deadline")
    func unreachableProbeIsDeadlineCapped() async throws {
        let recorder = ProbeRecorder()
        // A server two minutes slow is unreachable by ARITHMETIC against whatever
        // budget it was handed. Nothing sleeps.
        let harness = Harness(named: "unreachable", probe: Self.probe(recorder: recorder) { budget in
            unresponsiveLatencySeconds > budget
                ? .unreachable(diagnostic: IntelligenceMCPProbe.timedOutToken)
                : .connected(toolCount: 1)
        })
        let descriptor = Self.httpServer(named: "Beta")
        try await harness.store.save(descriptor)

        let started = Date()
        await harness.model.test(serverID: descriptor.id)
        let elapsed = Date().timeIntervalSince(started)

        #expect(harness.model.status(for: descriptor.id)
            == .unreachable(diagnostic: IntelligenceMCPProbe.timedOutToken))

        // The cap is the manager's own, handed over on every call…
        let budgets = await recorder.timeouts
        #expect(budgets == [MCPClientManager.callTimeoutSeconds])
        #expect(harness.model.probeTimeoutSeconds == 30)
        // …and it was INJECTED: waiting it out would have cost thirty seconds.
        #expect(elapsed < 5)
    }

    @Test("a probed answer outlives the switch that was never turned on")
    func probedStatusSurvivesADisabledSwitch() async throws {
        let recorder = ProbeRecorder()
        let harness = Harness(named: "probedWhileOff", probe: Self.probe(recorder: recorder) { _ in
            .connected(toolCount: 2)
        })
        let descriptor = Self.stdioServer(named: "Alpha")
        try await harness.store.save(descriptor)

        await harness.model.test(serverID: descriptor.id)

        #expect(harness.model.status(for: descriptor.id) == .connected(toolCount: 2))
        #expect(harness.settings.mcpServers.first?.isEnabled == false)
    }

    // MARK: Drafts

    @Test("a draft with nothing typed describes no server, and a full one round-trips")
    func draftDescribesAServerOnlyWhenItIsComplete() throws {
        let identifier = UUID()
        var draft = MCPServerDraft(existing: nil)
        #expect(draft.descriptor(id: identifier, existing: nil) == nil)

        draft.name = "  Alpha  "
        #expect(draft.descriptor(id: identifier, existing: nil) == nil, "a command is still missing")

        draft.command = "npx"
        draft.argumentsText = "-y\n\n @example/mcp \n"
        draft.environmentKeysText = "EXAMPLE_API_KEY\n"
        let described = try #require(draft.descriptor(id: identifier, existing: nil))
        #expect(described.name == "Alpha")
        #expect(described.endpoint == .stdio(
            command: "npx",
            arguments: ["-y", "@example/mcp"],
            environmentKeys: ["EXAMPLE_API_KEY"]
        ))
        // Saving describes; it never grants.
        #expect(described.isEnabled == false)
    }

    @Test("an address without a scheme is refused, and a blank credential is dropped")
    func draftRefusesBadAddressesAndBlankSecrets() {
        var draft = MCPServerDraft(existing: nil)
        draft.name = "Beta"
        draft.transport = .http
        draft.address = "example.invalid/mcp"
        #expect(draft.parsedAddress == nil)
        #expect(draft.descriptor(id: UUID(), existing: nil) == nil)

        draft.address = Self.httpAddress
        draft.headerKeysText = "Authorization\nX-Example"
        draft.secretValues = ["Authorization": " token ", "X-Example": "   "]
        #expect(draft.enteredSecretValues == ["Authorization": "token"])
        #expect(draft.descriptor(id: UUID(), existing: nil) != nil)
    }

    // MARK: Localization

    @Test("every app.preferences.intelligence.mcp.* key is in the catalog for all eight locales")
    func everyMCPKeyIsInTheCatalogForEveryLocale() throws {
        let catalog = try Self.stringCatalog()
        let keys = catalog.keys.filter { $0.hasPrefix("app.preferences.intelligence.mcp.") }
        #expect(keys.count >= 50, "the section, the sheet and the disclosure all publish keys")

        for key in keys.sorted() {
            let entry = try #require(catalog[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for locale in Self.shippedLocales {
                #expect(localizations[locale] != nil, "\(key) has no \(locale) entry")
            }
        }
    }

    @Test("the disclosure's own copy reached the shipped catalog, not just the default value")
    func bulgarianCopyIsNotEnglish() {
        let resources = [
            PreferencesStrings.mcpConsentTitle,
            PreferencesStrings.mcpConsentInjectionItem,
            PreferencesStrings.mcpConsentPlaybackItem,
            PreferencesStrings.mcpConsentProcessItem,
            PreferencesStrings.mcpSection,
            PreferencesStrings.mcpTest,
        ]
        for resource in resources {
            let english = resource.resolved(in: Locale(identifier: "en"))
            #expect(!english.isEmpty)
            #expect(
                resource.resolved(in: Locale(identifier: "bg")) != english,
                "bg still English for \(resource.key)"
            )
            #expect(
                resource.resolved(in: Locale(identifier: "de")) != english,
                "de still English for \(resource.key)"
            )
        }
    }
}

// MARK: - Fixtures

private extension IntelligenceMCPSectionTests {
    static let suitePrefix = "com.example.macamp.tests.mcpSection"
    static let secretValue = "sk-not-a-real-token-0123456789"
    static let httpAddress = "https://example.invalid/mcp"
    static let shippedLocales = ["bg", "de", "en", "es", "fr", "it", "pseudo", "ru"]

    /// One store, one model, one `UserDefaults` suite nothing else writes to.
    struct Harness {
        let settings: AppSettings
        let store: MCPServerConfigStore
        let model: MCPServersSectionModel

        @MainActor
        init(named name: String, probe: @escaping MCPServerProbing = { _, _, _ in .connected(toolCount: 0) }) {
            let defaults = Harness.defaults(named: "\(suitePrefix).\(name)")
            settings = AppSettings(defaults: defaults)
            store = MCPServerConfigStore(settings: settings, secrets: InMemorySecretStore())
            model = MCPServersSectionModel(store: store, probe: probe)
        }

        /// Neither half of the grant moved.
        @MainActor
        func expectUntouched(_ serverID: UUID) {
            #expect(settings.mcpServers.first { $0.id == serverID }?.isEnabled == false)
            #expect(settings.hasMCPConsent(forServerID: serverID) == false)
            #expect(store.usableServers.isEmpty)
        }

        private static func defaults(named name: String) -> UserDefaults {
            guard let store = UserDefaults(suiteName: name) else { return .standard }
            store.removePersistentDomain(forName: name)
            return store
        }
    }

    /// Records every deadline it was handed, so the cap can be asserted rather than
    /// waited out.
    actor ProbeRecorder {
        private(set) var timeouts: [TimeInterval] = []
        private(set) var secrets: [[String: String]] = []

        func record(timeout: TimeInterval, secrets resolved: [String: String]) {
            timeouts.append(timeout)
            secrets.append(resolved)
        }
    }

    static func probe(
        recorder: ProbeRecorder,
        answering outcome: @escaping @Sendable (TimeInterval) -> MCPServerProbeOutcome
    ) -> MCPServerProbing {
        { _, resolved, timeout in
            await recorder.record(timeout: timeout, secrets: resolved)
            return outcome(timeout)
        }
    }

    static func stdioServer(named name: String) -> MCPServerDescriptor {
        MCPServerDescriptor(
            name: name,
            endpoint: .stdio(command: "npx", arguments: ["-y", "@example/mcp"], environmentKeys: ["EXAMPLE_API_KEY"])
        )
    }

    static func httpServer(named name: String) -> MCPServerDescriptor {
        MCPServerDescriptor(
            // Force-unwrap-free: a literal that cannot fail still goes through the
            // failable initializer, so `.invalid` keeps the suite off the network.
            endpoint: .streamableHTTP(
                url: URL(string: httpAddress) ?? URL(fileURLWithPath: "/"),
                headerKeys: ["Authorization"]
            ),
            named: name
        )
    }

    /// The catalog the app ships, read from source rather than resolved.
    ///
    /// A missing key resolves to its English `defaultValue` in every locale, so
    /// asking the resource machinery whether `bg` exists always answers yes. The
    /// file is the only thing that can be asked honestly.
    static func stringCatalog() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/Localizable.xcstrings")
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let catalog = try #require(parsed as? [String: Any])
        return try #require(catalog["strings"] as? [String: Any])
    }
}

private extension MCPServerDescriptor {
    /// Named-after-endpoint initializer, so the HTTP fixture reads in the same order
    /// as the stdio one without tripping `function_parameter_count`.
    init(endpoint: Endpoint, named name: String) {
        self.init(name: name, endpoint: endpoint)
    }
}
