// IntelligenceMCPEditStrings — the add/edit sheet, in words.
//
// Split from ``IntelligenceMCPStrings`` on the 400-line rule the other five
// `PreferencesStrings` extension files were split on. Same namespace, same call
// shape, no behaviour of its own.
//
// ── THE FIELD CAPTIONS ARE THE SECURITY MODEL, SPELLED OUT ───────────────────
//
// ``MCPServerDescriptor`` stores credential NAMES and never values — that is what
// makes it safe to write to disk as JSON. The two "names only" captions are the
// listener-facing half of that invariant: a field labelled "Environment variables"
// with no explanation invites somebody to paste a token into it, which would put
// the token in `UserDefaults` where `MCPServerConfigPersistenceTests` proves it must
// never appear. The value goes in the separate secure field below, and from there
// to the Keychain.
import Foundation

extension PreferencesStrings {
    // MARK: Chrome

    static let mcpEditAddTitle = LocalizedStringResource(
        "app.preferences.intelligence.mcp.edit.title.add",
        defaultValue: "Add MCP Server",
        comment: "Title of the sheet that describes a new MCP server"
    )

    static let mcpEditChangeTitle = LocalizedStringResource(
        "app.preferences.intelligence.mcp.edit.title.change",
        defaultValue: "Edit MCP Server",
        comment: "Title of the sheet that edits an existing MCP server"
    )

    static let mcpEditSubtitle = LocalizedStringResource(
        "app.preferences.intelligence.mcp.edit.subtitle",
        defaultValue: "Credential names are saved with the server. Their values go to your Keychain.",
        comment: "Subtitle of the MCP server sheet, stating where names and values are each stored"
    )

    static let mcpEditSave = LocalizedStringResource(
        "app.preferences.intelligence.mcp.edit.save",
        defaultValue: "Save",
        comment: "Button committing the MCP server sheet"
    )

    static let mcpEditSaveHelp = LocalizedStringResource(
        "app.preferences.intelligence.mcp.edit.save.help",
        defaultValue: "Save this server. It stays off until you switch it on.",
        comment: "Tooltip of the button committing the MCP server sheet"
    )

    static let mcpEditCancel = LocalizedStringResource(
        "app.preferences.intelligence.mcp.edit.cancel",
        defaultValue: "Cancel",
        comment: "Button discarding the MCP server sheet"
    )

    // MARK: Fields

    static let mcpFieldName = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.name",
        defaultValue: "Name",
        comment: "Label of the field naming an MCP server"
    )

    static let mcpFieldNamePrompt = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.name.prompt",
        defaultValue: "My tool server",
        comment: "Placeholder of the field naming an MCP server"
    )

    static let mcpFieldTransport = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.transport",
        defaultValue: "Reach it by",
        comment: "Label of the picker choosing how MacAMP reaches an MCP server"
    )

    static let mcpFieldCommand = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.command",
        defaultValue: "Command",
        comment: "Label of the field holding the program that starts an MCP server"
    )

    static let mcpFieldCommandCaption = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.command.caption",
        defaultValue: "A program on this Mac. It runs with your permissions whenever the assistant uses this server.",
        comment: "Caption stating that a command-backed MCP server runs a local program"
    )

    static let mcpFieldArguments = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.arguments",
        defaultValue: "Arguments",
        comment: "Label of the field holding an MCP server command's argument vector"
    )

    static let mcpFieldArgumentsCaption = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.arguments.caption",
        defaultValue: "One argument per line, in order.",
        comment: "Caption explaining the one-per-line format of the argument field"
    )

    static let mcpFieldURL = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.url",
        defaultValue: "Address",
        comment: "Label of the field holding the address an MCP server answers at"
    )

    static let mcpFieldURLCaption = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.url.caption",
        defaultValue: "The full address the server answers at, including http:// or https://.",
        comment: "Caption stating the required form of an MCP server address"
    )

    static let mcpFieldURLInvalid = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.url.invalid",
        defaultValue: "That is not an address MacAMP can reach.",
        comment: "Validation message shown when the entered MCP server address cannot be parsed"
    )

    static let mcpFieldEnvironmentKeys = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.environmentKeys",
        defaultValue: "Environment variables",
        comment: "Label of the field listing the environment variable names an MCP server's command needs"
    )

    static let mcpFieldEnvironmentKeysCaption = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.environmentKeys.caption",
        defaultValue: "Names only, one per line — for example GITHUB_TOKEN. Enter the values below.",
        comment: "Caption stating that only environment variable names belong in this field"
    )

    static let mcpFieldHeaderKeys = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.headerKeys",
        defaultValue: "Request headers",
        comment: "Label of the field listing the request header names an MCP server needs"
    )

    static let mcpFieldHeaderKeysCaption = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.headerKeys.caption",
        defaultValue: "Names only, one per line — for example Authorization. Enter the values below.",
        comment: "Caption stating that only request header names belong in this field"
    )

    static let mcpFieldSecretsHeading = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.secrets.heading",
        defaultValue: "Credential values",
        comment: "Heading above the secure fields holding one MCP server's credential values"
    )

    static let mcpFieldSecretsCaption = LocalizedStringResource(
        "app.preferences.intelligence.mcp.field.secrets.caption",
        defaultValue: "Stored in your Keychain, never in preferences. Leave one blank to keep what is already saved.",
        comment: "Caption stating where MCP credential values are stored and what a blank field means"
    )
}
