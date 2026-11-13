// IntelligenceMCPConsentStrings — the FOURTH disclosure, and why it is a fourth.
//
// ── WHAT CHANGED, AGAIN ──────────────────────────────────────────────────────
//
// The connect-time sheet describes a payload computed before a request leaves. The
// browsing sheet describes a named PROVIDER that may ask for more while it answers.
// The external-access sheet describes an unnamed program on this Mac READING the
// library through MacAMP's own server.
//
// This one is the direction none of those cover: text arriving from somewhere else
// and being handed to the model as if MacAMP had written it. The three risks below
// are the ones that are specific to that direction, and each is stated because it
// is not obvious from "add a server":
//
//   1. PROMPT INJECTION. A tool result is not data the assistant merely reports —
//      it lands in the same context window as the listener's own words, and a
//      result that contains instructions can be followed.
//   2. PLAYBACK. Control tools are KEPT (recorded decision): every write to the
//      library still waits behind the proposal review sheet, and playback is
//      reversible in one press. So the copy NAMES the risk instead of removing the
//      capability — which is the honest trade, and the reason this line exists.
//   3. LOCAL EXECUTION. A command server is a program started with the listener's
//      full permissions, and MacAMP is NOT sandboxed (`macampMac.entitlements`
//      declares no app-sandbox key). That is a bigger grant than "an app may see
//      your music", so it is spelled out rather than implied by the word "command".
//
// The server's NAME and its COMMAND are things the listener typed. They arrive as
// interpolated values; this sheet never composes a sentence out of `Text(verbatim:)`
// fragments glued together.
import Foundation

extension PreferencesStrings {
    // MARK: Chrome

    static let mcpConsentTitle = LocalizedStringResource(
        "app.preferences.intelligence.mcp.consent.title",
        defaultValue: "Let the assistant use this server?",
        comment: "Title of the sheet shown before an external MCP server is enabled for the first time"
    )

    static let mcpConsentAccept = LocalizedStringResource(
        "app.preferences.intelligence.mcp.consent.accept",
        defaultValue: "Enable Server",
        comment: "Button accepting the MCP server trust disclosure"
    )

    static let mcpConsentAcceptHelp = LocalizedStringResource(
        "app.preferences.intelligence.mcp.consent.accept.help",
        defaultValue: "Agree to the above and switch this server on.",
        comment: "Tooltip of the button accepting the MCP server trust disclosure"
    )

    static let mcpConsentCancel = LocalizedStringResource(
        "app.preferences.intelligence.mcp.consent.cancel",
        defaultValue: "Not Now",
        comment: "Button declining the MCP server trust disclosure"
    )

    static let mcpConsentCancelHelp = LocalizedStringResource(
        "app.preferences.intelligence.mcp.consent.cancel.help",
        defaultValue: "Leave this server switched off. Nothing is saved and nothing is contacted.",
        comment: "Tooltip of the button declining the MCP server trust disclosure"
    )

    // MARK: The disclosure

    static let mcpConsentHeading = LocalizedStringResource(
        "app.preferences.intelligence.mcp.consent.heading",
        defaultValue: "What you are agreeing to:",
        comment: "Heading above the itemised risks of enabling an external MCP server"
    )

    static let mcpConsentInjectionItem = LocalizedStringResource(
        "app.preferences.intelligence.mcp.consent.injection",
        defaultValue: """
        Results come from an outside service, and they can contain instructions written to look like yours. \
        The assistant may follow them.
        """,
        comment: "Disclosure item: a tool result is untrusted text that can carry instructions (prompt injection)"
    )

    static let mcpConsentPlaybackItem = LocalizedStringResource(
        "app.preferences.intelligence.mcp.consent.playback",
        defaultValue:
        "While playback control is on, instructions that arrive that way can start, change or stop your music.",
        comment: "Disclosure item: injected instructions can reach the playback-control tools"
    )

    static let mcpConsentProcessItem = LocalizedStringResource(
        "app.preferences.intelligence.mcp.consent.process",
        defaultValue: """
        A command server runs a program on this Mac with your full permissions. MacAMP is not sandboxed, \
        so that program can read and change anything you can.
        """,
        comment: "Disclosure item: a stdio MCP server executes a local program with the user's own permissions"
    )

    static let mcpConsentReviewNote = LocalizedStringResource(
        "app.preferences.intelligence.mcp.consent.review",
        defaultValue: "Changes to your library still wait for you in the review sheet, and playback is reversible.",
        comment: "Note stating which protections remain in force after this disclosure is accepted"
    )

    static let mcpConsentReversibleNote = LocalizedStringResource(
        "app.preferences.intelligence.mcp.consent.reversible",
        defaultValue: "Switch this server off again at any time in Preferences ▸ Intelligence.",
        comment: "Note stating how to withdraw the grant this disclosure requests"
    )

    /// Who is being trusted. The value is the name the listener typed.
    static func mcpConsentLead(server: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.mcp.consent.lead",
            defaultValue: "\(server) is not part of MacAMP, and MacAMP cannot check what it sends back.",
            comment: "Lead sentence naming the external MCP server this disclosure is about"
        )
    }

    /// The program THIS server would start. Only shown for a command server, and
    /// only ever the command — never its resolved environment.
    static func mcpConsentCommandItem(command: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.mcp.consent.command",
            defaultValue: "This one is a command server: enabling it lets MacAMP run \(command) on your Mac.",
            comment: "Disclosure item naming the local program a command-backed MCP server would start"
        )
    }
}
