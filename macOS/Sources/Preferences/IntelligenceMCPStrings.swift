// IntelligenceMCPStrings — the MCP servers section, in words.
//
// A SIXTH `PreferencesStrings` extension file, for the reason there are already
// five: `swiftlint --strict` caps a file at 400 lines, and extension members do not
// count against the parent declaration. Every call site still reads
// `PreferencesStrings.<name>`, so the split stays invisible to the views. The
// edit sheet and the trust disclosure carry their own files for the same reason.
//
// ── WHAT IS COPY HERE, AND WHAT IS DATA ──────────────────────────────────────
//
// A server's NAME, its command, its argument vector and its address are things the
// listener typed. They are DATA and are rendered `Text(verbatim:)` at the call
// site — never glued into a sentence here. What this file owns is the app's own
// voice: the heading, the buttons, the status vocabulary and the captions.
//
// ── THE DEADLINE IS A PARAMETER, NOT A SENTENCE ──────────────────────────────
//
// `mcpTimeoutCaption(seconds:)` is fed from ``MCPClientManager/callTimeoutSeconds``
// through ``MCPServersSectionModel/probeTimeoutSeconds``. Spelling "30 seconds" out
// here would put a second copy of an enforcement bound in the tree, and the copy
// the listener read is the one that binds.
import Foundation

extension PreferencesStrings {
    // MARK: Section chrome

    static let mcpSection = LocalizedStringResource(
        "app.preferences.intelligence.mcp.section",
        defaultValue: "MCP Servers",
        comment: "Heading of the section listing external Model Context Protocol servers the assistant may call"
    )

    static let mcpCaption = LocalizedStringResource(
        "app.preferences.intelligence.mcp.caption",
        defaultValue: "Let the assistant use tools published by other programs, beyond your own library.",
        comment: "Caption explaining what an MCP server adds to the assistant"
    )

    static let mcpNeedsIntelligence = LocalizedStringResource(
        "app.preferences.intelligence.mcp.needsIntelligence",
        defaultValue: "Turn on Intelligence above to use MCP servers.",
        comment: "Caption shown when the master Intelligence switch is off and the MCP section is inert"
    )

    static let mcpEmpty = LocalizedStringResource(
        "app.preferences.intelligence.mcp.empty",
        defaultValue: "No servers yet. Add one to give the assistant tools from outside MacAMP.",
        comment: "Placeholder shown when no MCP server has been configured"
    )

    static let mcpPersistFailed = LocalizedStringResource(
        "app.preferences.intelligence.mcp.persistFailed",
        defaultValue: "That change could not be saved. Check that your Keychain is unlocked, then try again.",
        comment: "Caption shown when saving or removing an MCP server could not settle both stores"
    )

    // MARK: Actions

    static let mcpAdd = LocalizedStringResource(
        "app.preferences.intelligence.mcp.add",
        defaultValue: "Add Server…",
        comment: "Button opening the sheet that adds an MCP server"
    )

    static let mcpAddHelp = LocalizedStringResource(
        "app.preferences.intelligence.mcp.add.help",
        defaultValue: "Describe a server the assistant may call. Nothing is contacted until you enable it.",
        comment: "Tooltip of the button that adds an MCP server"
    )

    static let mcpEdit = LocalizedStringResource(
        "app.preferences.intelligence.mcp.edit",
        defaultValue: "Edit…",
        comment: "Button opening the sheet that edits one MCP server"
    )

    static let mcpEditHelp = LocalizedStringResource(
        "app.preferences.intelligence.mcp.edit.help",
        defaultValue: "Change this server's name, how MacAMP reaches it, and which credentials it needs.",
        comment: "Tooltip of the button that edits one MCP server"
    )

    static let mcpRemove = LocalizedStringResource(
        "app.preferences.intelligence.mcp.remove",
        defaultValue: "Remove",
        comment: "Button forgetting one MCP server"
    )

    static let mcpRemoveHelp = LocalizedStringResource(
        "app.preferences.intelligence.mcp.remove.help",
        defaultValue: "Forget this server, delete its saved credentials, and withdraw your permission.",
        comment: "Tooltip of the button that removes one MCP server"
    )

    static let mcpTest = LocalizedStringResource(
        "app.preferences.intelligence.mcp.test",
        defaultValue: "Test Connection",
        comment: "Button that connects to one MCP server once and reports what it publishes"
    )

    static let mcpTestHelp = LocalizedStringResource(
        "app.preferences.intelligence.mcp.test.help",
        defaultValue: "Connect once and report how many tools this server publishes.",
        comment: "Tooltip of the button that tests one MCP server's connection"
    )

    static let mcpEnableHelp = LocalizedStringResource(
        "app.preferences.intelligence.mcp.enable.help",
        defaultValue: "Let the assistant call this server's tools while it answers.",
        comment: "Tooltip of the per-server enable switch"
    )

    // MARK: Transport

    static let mcpTransportStdio = LocalizedStringResource(
        "app.preferences.intelligence.mcp.transport.stdio",
        defaultValue: "Command on this Mac",
        comment: "Label for a server MacAMP starts as a program on this Mac"
    )

    static let mcpTransportHTTP = LocalizedStringResource(
        "app.preferences.intelligence.mcp.transport.http",
        defaultValue: "Address",
        comment: "Label for a server MacAMP reaches over HTTP at an address"
    )

    // MARK: Status

    static let mcpStatusDisabled = LocalizedStringResource(
        "app.preferences.intelligence.mcp.status.disabled",
        defaultValue: "Off",
        comment: "Status of an MCP server that is switched off"
    )

    static let mcpStatusUntested = LocalizedStringResource(
        "app.preferences.intelligence.mcp.status.untested",
        defaultValue: "Not tested yet",
        comment: "Status of an MCP server that has never been contacted"
    )

    static let mcpStatusTesting = LocalizedStringResource(
        "app.preferences.intelligence.mcp.status.testing",
        defaultValue: "Connecting…",
        comment: "Status of an MCP server a connection test is currently running against"
    )

    static let mcpStatusUnreachable = LocalizedStringResource(
        "app.preferences.intelligence.mcp.status.unreachable",
        defaultValue: "Could not be reached",
        comment: "Status of an MCP server that did not answer"
    )

    /// How many tools a reachable server published. The count is DATA.
    static func mcpStatusConnected(tools: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.mcp.status.connected",
            defaultValue: "Connected — ^[\(tools) tool](inflect: true)",
            comment: "Status of a reachable MCP server, with the number of tools it publishes"
        )
    }

    /// The deadline one test may take, forwarded from ``MCPClientManager``.
    static func mcpTimeoutCaption(seconds: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.mcp.timeout.caption",
            defaultValue: "A test gives up after \(seconds) seconds and reports the server as unreachable.",
            comment: "Caption stating the deadline a single MCP connection test is bounded by"
        )
    }
}
