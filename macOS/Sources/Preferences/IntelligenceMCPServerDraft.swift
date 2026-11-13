// IntelligenceMCPServerDraft — what has been typed, before it is a server.
//
// A VALUE, not an `@Observable` object, because the whole point of a draft is that
// nothing outside the sheet can see it: `@State` on a struct gives the sheet its own
// copy, and Cancel is then literally free. The one thing that must not be a value is
// the commit, and that is `MCPServerConfigStore`'s.
//
// ── THE TEXT-TO-LIST RULE IS ONE FUNCTION ────────────────────────────────────
//
// Arguments, environment-variable names and header names are all "one per line,
// trimmed, blanks dropped". Three fields sharing one parser means a listener who
// leaves a trailing newline in one field gets the same answer in all three, and an
// argument vector never silently gains an empty string — which for a command server
// is an argument the child really receives.
//
// ── AN INVALID DRAFT HAS NO DESCRIPTOR ───────────────────────────────────────
//
// ``descriptor(id:existing:)`` returns `nil` rather than a half-built server, so the
// Save button's enabled state and the commit path read the SAME judgement. A
// separate `isValid` flag would be a second copy of that rule, free to disagree.
import AIConnectorMCP
import Foundation

/// One MCP server as it is being typed.
struct MCPServerDraft: Equatable {
    /// Which arm of ``MCPServerDescriptor/Endpoint`` the fields describe.
    enum Transport: Hashable, CaseIterable {
        case stdio
        case http
    }

    var name = ""
    var transport: Transport = .stdio
    var command = ""
    var argumentsText = ""
    var environmentKeysText = ""
    var address = ""
    var headerKeysText = ""

    /// Values typed for the declared credential NAMES. Never persisted with the
    /// descriptor — they travel to the Keychain through the store.
    var secretValues: [String: String] = [:]

    init(existing: MCPServerDescriptor?) {
        guard let existing else { return }
        name = existing.name
        switch existing.endpoint {
        case let .stdio(command, arguments, environmentKeys):
            transport = .stdio
            self.command = command
            argumentsText = arguments.joined(separator: "\n")
            environmentKeysText = environmentKeys.joined(separator: "\n")
        case let .streamableHTTP(url, headerKeys):
            transport = .http
            address = url.absoluteString
            headerKeysText = headerKeys.joined(separator: "\n")
        }
    }
}

extension MCPServerDraft {
    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedCommand: String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The typed address, if it is one MacAMP could actually reach.
    ///
    /// A scheme AND a host are both required: `URL(string: "example.com/mcp")`
    /// succeeds and yields a relative URL with no host, which fails much later and
    /// much less clearly than refusing it here.
    var parsedAddress: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// The credential names this draft declares, in the order they were typed.
    var secretNames: [String] {
        switch transport {
        case .stdio: Self.lines(environmentKeysText)
        case .http: Self.lines(headerKeysText)
        }
    }

    /// Only the values actually typed. A blank field means "keep what is saved",
    /// so it is dropped rather than committed as an empty credential.
    var enteredSecretValues: [String: String] {
        secretNames.reduce(into: [String: String]()) { entered, secretName in
            let value = secretValues[secretName]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard value.isEmpty == false else { return }
            entered[secretName] = value
        }
    }

    /// The server this draft describes, or `nil` while it describes none.
    ///
    /// `isEnabled` is carried over from `existing` and is `false` for a new server:
    /// saving describes, it never grants. `isConsented` is carried for shape only —
    /// `MCPServerConfigStore` overwrites it from the consent record regardless.
    func descriptor(id: UUID, existing: MCPServerDescriptor?) -> MCPServerDescriptor? {
        guard trimmedName.isEmpty == false, let endpoint = endpoint() else { return nil }
        return MCPServerDescriptor(
            id: id,
            name: trimmedName,
            endpoint: endpoint,
            isEnabled: existing?.isEnabled ?? false,
            isConsented: existing?.isConsented ?? false
        )
    }

    private func endpoint() -> MCPServerDescriptor.Endpoint? {
        switch transport {
        case .stdio:
            guard trimmedCommand.isEmpty == false else { return nil }
            return .stdio(
                command: trimmedCommand,
                arguments: Self.lines(argumentsText),
                environmentKeys: Self.lines(environmentKeysText)
            )
        case .http:
            guard let url = parsedAddress else { return nil }
            return .streamableHTTP(url: url, headerKeys: Self.lines(headerKeysText))
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
    }
}
