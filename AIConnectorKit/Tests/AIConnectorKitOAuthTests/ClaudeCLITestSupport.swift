// Scaffolding for the Claude Code CLI reuse suites.
//
// ZERO subprocesses and ZERO filesystem access: both host seams are replaced, so
// the suite can never read — let alone write — a developer's real Claude Code
// login. That is not merely hygiene here. The production path writes back to
// another application's credential, and a test that reached the real one could
// sign the developer out of their own CLI.
//
// Every fake secret is prefixed `test-token-`, matching the rest of this target,
// so `OAuthSecretLeakTests`' grep covers these paths too.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation

enum ClaudeCLIFixture {
    static let accessToken = "test-token-cli-access-alpha"
    static let refreshToken = "test-token-cli-refresh-alpha"
    static let fileAccessToken = "test-token-cli-file-access-alpha"
    static let fileRefreshToken = "test-token-cli-file-refresh-alpha"
    static let rotatedAccessToken = "test-token-cli-access-beta"
    static let rotatedRefreshToken = "test-token-cli-refresh-beta"

    static let account = "listener@example.invalid"
    static let filePath = "/fixture/home/.claude/.credentials.json"
    static let variantService = "Claude Code-credentials-9f2a1c"

    /// `2027-01-01T00:00:00Z`, in the JavaScript milliseconds the CLI writes.
    static let expiryMilliseconds = 1_798_761_600_000

    static var expiry: Date {
        Date(timeIntervalSince1970: Double(expiryMilliseconds) / 1000)
    }

    /// The nested envelope current CLI versions write.
    static func wrappedBlob(
        accessToken: String = ClaudeCLIFixture.accessToken,
        refreshToken: String = ClaudeCLIFixture.refreshToken,
        expiresAt: Int = ClaudeCLIFixture.expiryMilliseconds,
        subscriptionType: String = "max"
    ) -> String {
        """
        {"claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"\(refreshToken)",\
        "expiresAt":\(expiresAt),"subscriptionType":"\(subscriptionType)",\
        "scopes":["user:profile","user:inference"],"unknownFutureField":"keep-me"},\
        "otherTopLevelKey":42}
        """
    }

    /// The flat envelope older CLI versions write.
    static func flatBlob(
        accessToken: String = ClaudeCLIFixture.fileAccessToken,
        refreshToken: String = ClaudeCLIFixture.fileRefreshToken,
        expiresAt: Int = ClaudeCLIFixture.expiryMilliseconds,
        subscriptionType: String = "pro"
    ) -> String {
        """
        {"accessToken":"\(accessToken)","refreshToken":"\(refreshToken)",\
        "expiresAt":\(expiresAt),"subscriptionType":"\(subscriptionType)","legacyFlag":true}
        """
    }

    /// A per-MCP-server grant: same service-name family, not a user login.
    static let mcpOnlyBlob = """
    {"mcpOAuth":{"https://mcp.example.invalid":{"accessToken":"test-token-cli-mcp-alpha",\
    "refreshToken":"test-token-cli-mcp-refresh"}}}
    """

    /// One `security dump-keychain` attribute block per service name.
    static func dumpOutput(services: [String]) -> String {
        services.map { service in
            """
            keychain: "/Users/fixture/Library/Keychains/login.keychain-db"
            class: "genp"
            attributes:
                0x00000007 <blob>="\(service)"
                "acct"<blob>="\(account)"
                "svce"<blob>="\(service)"
            """
        }
        .joined(separator: "\n")
    }

    /// The attribute dump `security find-generic-password -s <service>` prints.
    static func itemOutput(service: String, account: String = ClaudeCLIFixture.account) -> String {
        """
        keychain: "/Users/fixture/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "acct"<blob>="\(account)"
            "svce"<blob>="\(service)"
        """
    }
}

/// Scripted `/usr/bin/security`, recording every invocation.
///
/// A write actually MUTATES the stored blob, so a suite can assert that a
/// write-back is visible to the next read the way the real command behaves.
actor FakeSecurityCommand: SecurityCommandRunning {
    struct Write: Equatable {
        var service: String
        var account: String
        var blob: String
    }

    private let dump: SecurityCommandResult
    private var blobs: [String: String]
    private let accounts: [String: String]
    private let writeSucceeds: Bool

    private(set) var invocations: [[String]] = []
    private(set) var writes: [Write] = []

    init(
        dump: SecurityCommandResult = SecurityCommandResult(exitCode: 1),
        blobs: [String: String] = [:],
        accounts: [String: String] = [:],
        writeSucceeds: Bool = true
    ) {
        self.dump = dump
        self.blobs = blobs
        self.accounts = accounts
        self.writeSucceeds = writeSucceeds
    }

    func run(arguments: [String]) async -> SecurityCommandResult {
        invocations.append(arguments)
        switch arguments.first {
        case "dump-keychain": return dump
        case "find-generic-password": return find(arguments)
        case "add-generic-password": return add(arguments)
        default: return SecurityCommandResult(exitCode: 1)
        }
    }

    /// The blob currently stored for `service`, as the real Keychain would return.
    func blob(for service: String) -> String? {
        blobs[service]
    }

    /// Argument values that followed `flag`, in call order.
    func values(after flag: String) -> [String] {
        invocations.compactMap { arguments in
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }
    }

    private func find(_ arguments: [String]) -> SecurityCommandResult {
        guard let service = value(of: "-s", in: arguments) else { return SecurityCommandResult(exitCode: 1) }
        if arguments.contains("-w") {
            guard let blob = blobs[service] else { return SecurityCommandResult(exitCode: 44) }
            return SecurityCommandResult(exitCode: 0, standardOutput: blob + "\n")
        }
        guard let attributes = accounts[service] else { return SecurityCommandResult(exitCode: 44) }
        return SecurityCommandResult(exitCode: 0, standardOutput: attributes)
    }

    private func add(_ arguments: [String]) -> SecurityCommandResult {
        guard let service = value(of: "-s", in: arguments),
              let account = value(of: "-a", in: arguments),
              let blob = value(of: "-w", in: arguments)
        else {
            return SecurityCommandResult(exitCode: 1)
        }
        guard writeSucceeds else { return SecurityCommandResult(exitCode: 45) }
        writes.append(Write(service: service, account: account, blob: blob))
        blobs[service] = blob
        return SecurityCommandResult(exitCode: 0)
    }

    private func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

/// An in-memory stand-in for the CLI's credential file.
actor FakeCredentialFiles: CredentialFileAccessing {
    private var contents: [String: Data]
    private let writeSucceeds: Bool
    private(set) var writeCount = 0

    init(contents: [String: String] = [:], writeSucceeds: Bool = true) {
        self.contents = contents.mapValues { Data($0.utf8) }
        self.writeSucceeds = writeSucceeds
    }

    func read(path: String) async -> Data? {
        contents[path]
    }

    @discardableResult
    func write(_ data: Data, path: String) async -> Bool {
        guard writeSucceeds else { return false }
        writeCount += 1
        contents[path] = data
        return true
    }

    func text(at path: String) -> String? {
        contents[path].flatMap { String(bytes: $0, encoding: .utf8) }
    }
}

/// A source that reports one fixed credential and records every write-back.
actor StubExternalCredentialSource: ExternalCredentialSource {
    private var reading: ExternalCredentialReading?
    private let writeSucceeds: Bool
    private(set) var writtenCredentials: [OAuthCredentials] = []

    init(reading: ExternalCredentialReading?, writeSucceeds: Bool = true) {
        self.reading = reading
        self.writeSucceeds = writeSucceeds
    }

    func load() async -> ExternalCredentialReading? {
        reading
    }

    @discardableResult
    func writeBack(_ credentials: OAuthCredentials, to _: ExternalCredentialOrigin) async -> Bool {
        writtenCredentials.append(credentials)
        guard writeSucceeds else { return false }
        reading?.credentials = credentials
        return true
    }
}

extension ExternalCredentialOrigin {
    /// The address a Keychain-sourced fixture reports.
    static var keychainFixture: ExternalCredentialOrigin {
        ExternalCredentialOrigin(
            kind: .keychain,
            locator: ClaudeCLICredentialStore.primaryKeychainService,
            account: ClaudeCLIFixture.account,
            isWrapped: true
        )
    }
}
