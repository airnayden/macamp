@testable import AIConnectorMCP

// MCPServerDescriptorTests — the package-graph proof, executed rather than assumed.
//
// The claim this suite exists to make is a BUILD claim: that a remote SwiftPM
// dependency declared inside a nested local package resolves, links, and is
// reachable at AIConnectorKit's own platform floor (macOS 14 / iOS 17 — the SDK
// declares 13 / 16, so the floor is ours, not theirs). A test that only exercised
// this module's own value type would pass identically with the SDK unlinked, which
// is precisely the failure worth catching. So the first case reads a constant that
// can ONLY come from the SDK.
//
// The rest pin the descriptor's own contract: the two-case reachability fork, and
// the JSON round-trip a later todo persists it through — including the guarantee
// that an environment VALUE has nowhere to hide in the encoded form.
import Foundation
import MCP
import Testing

@Suite("MCPServerDescriptorTests")
struct MCPServerDescriptorTests {
    @Test("The negotiated protocol version is read from the linked SDK, not restated")
    func protocolVersionComesFromTheSDK() {
        #expect(MCPServerDescriptor.protocolVersion == MCP.Version.latest)
        #expect(MCP.Version.supported.contains(MCPServerDescriptor.protocolVersion))
    }

    @Test("The negotiated version is a dated MCP revision")
    func protocolVersionIsADatedRevision() throws {
        let version = MCPServerDescriptor.protocolVersion
        let parsed = try #require(
            version.wholeMatch(of: /\d{4}-\d{2}-\d{2}/),
            "expected a YYYY-MM-DD spec revision, got \(version)"
        )
        #expect(parsed.isEmpty == false)
    }

    @Test("An HTTP endpoint and a stdio endpoint are never equal")
    func endpointsDistinguishReachability() throws {
        let url = try #require(URL(string: "http://127.0.0.1:46114"))
        let identity = UUID()
        let http = MCPServerDescriptor(
            id: identity,
            name: "Alpha",
            endpoint: .streamableHTTP(url: url, headerKeys: [])
        )
        let stdio = MCPServerDescriptor(
            id: identity,
            name: "Alpha",
            endpoint: .stdio(command: "/usr/local/bin/alpha", arguments: [], environmentKeys: [])
        )

        #expect(http != stdio)
        #expect(http.id == stdio.id)
    }

    @Test("Arguments are part of a stdio endpoint's identity")
    func stdioArgumentsParticipateInEquality() {
        let bare = MCPServerDescriptor.Endpoint.stdio(
            command: "/usr/local/bin/some-mcp-server",
            arguments: [],
            environmentKeys: []
        )
        let withFlag = MCPServerDescriptor.Endpoint.stdio(
            command: "/usr/local/bin/some-mcp-server",
            arguments: ["--stdio"],
            environmentKeys: []
        )

        #expect(bare != withFlag)
    }

    @Test("A server is only usable once it is both enabled and consented")
    func usabilityRequiresBothFlags() throws {
        let url = try #require(URL(string: "https://example.invalid/mcp"))
        var descriptor = MCPServerDescriptor(name: "Alpha", endpoint: .streamableHTTP(url: url, headerKeys: []))

        #expect(descriptor.isUsable == false)
        descriptor.isEnabled = true
        #expect(descriptor.isUsable == false)
        descriptor.isConsented = true
        #expect(descriptor.isUsable)
    }

    @Test("A descriptor round-trips through JSON and carries only environment NAMES")
    func descriptorRoundTripsWithoutSecretValues() throws {
        let descriptor = MCPServerDescriptor(
            name: "Alpha",
            endpoint: .stdio(
                command: "npx",
                arguments: ["-y", "@example/mcp"],
                environmentKeys: ["EXAMPLE_API_KEY"]
            ),
            isEnabled: true,
            isConsented: true
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(MCPServerDescriptor.self, from: data)
        #expect(decoded == descriptor)

        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("EXAMPLE_API_KEY"))
        #expect(text.contains("secret") == false)
    }
}
