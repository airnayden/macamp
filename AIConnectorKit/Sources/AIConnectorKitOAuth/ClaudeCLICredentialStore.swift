// ClaudeCLICredentialStore — reuse of a Claude Code CLI login that is already on
// this Mac.
//
// ══ TERMS OF SERVICE — READ BEFORE CHANGING ANYTHING IN THIS FILE ═════════════
//
// Anthropic's February 2026 Terms of Service PROHIBIT third-party applications
// from using Claude Code OAuth tokens, and that prohibition is enforced
// server-side: Anthropic can and does refuse requests it attributes to a client
// other than Claude Code. This file therefore exists for ONE reason — MacAMP's
// owner asked for it explicitly, for their own personal use on their own machine,
// mirroring what the `jarvis` project already does with the same credentials.
//
// It is NOT a supported path, NOT something to recommend to a listener, and NOT a
// justification for widening reuse to other providers. The code below is
// deliberately read-mostly: it never creates a Claude Code credential, never
// deletes one, and writes back only a token the provider itself just rotated.
//
// ══ DISCOVERY ORDER ═══════════════════════════════════════════════════════════
//
//   1. Keychain. `security dump-keychain` ENUMERATES generic-password services
//      (attributes only — no `-d`, so it never prompts), and every service named
//      `Claude Code-credentials` or `Claude Code-credentials-<lowercase hex>` is a
//      candidate. `security find-generic-password -s <service> -w` then reads one.
//      THAT read may raise the standard macOS authorisation prompt; approving it
//      once is what makes reuse work unattended afterwards.
//      A dump that fails — a locked keychain, a hardened environment — falls back
//      to probing the primary service directly, because the enumeration is an
//      optimisation over a name we already know.
//   2. `~/.claude/.credentials.json`, and ONLY when the Keychain produced nothing.
//      Older CLI versions, and installs on machines with no login keychain, store
//      the same envelope as a plain file.
//
// The winning address is memoised so the enumeration — the only expensive step —
// runs once per process, while the blob itself is re-read every time so a
// rotation performed by the CLI is picked up rather than cached over.
import AIConnectorKit
import Foundation

/// Reuses the Claude Code CLI's stored login, when there is one.
///
/// An `actor` because the memoised address is mutable state read from arbitrary
/// tasks (a registry probe, a token resolution, a refresh write-back).
public actor ClaudeCLICredentialStore: ExternalCredentialSource {
    /// The generic-password service the CLI writes under.
    public static let primaryKeychainService = "Claude Code-credentials"

    /// `~/.claude/.credentials.json`, expanded against the real home directory.
    ///
    /// `macampMac` is unsandboxed, so this is the listener's actual home rather
    /// than a container — which is the whole point, since the CLI wrote it there.
    public static var defaultCredentialsFilePath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
    }

    /// Where a credential was found, before its envelope has been parsed.
    enum Candidate: Equatable {
        case keychain(service: String)
        case file(path: String)
    }

    private let security: any SecurityCommandRunning
    private let files: any CredentialFileAccessing
    private let filePath: String

    /// The address the last successful read came from. An optimisation only —
    /// dropped the moment it stops yielding a credential.
    private var memoisedOrigin: ExternalCredentialOrigin?

    /// - Parameters:
    ///   - security: The `/usr/bin/security` seam. Tests inject a scripted runner.
    ///   - files: The credential-file seam. Tests inject an in-memory one.
    ///   - filePath: The CLI's credential file. Injectable so a test never reads
    ///     the developer's real login.
    public init(
        security: any SecurityCommandRunning = SecurityCommandRunner(),
        files: any CredentialFileAccessing = CredentialFileAccessor(),
        filePath: String = ClaudeCLICredentialStore.defaultCredentialsFilePath
    ) {
        self.security = security
        self.files = files
        self.filePath = filePath
    }

    public func load() async -> ExternalCredentialReading? {
        if let memoisedOrigin, let reading = await read(from: memoisedOrigin) {
            return reading
        }
        memoisedOrigin = nil
        for candidate in await candidates() {
            guard let reading = await read(candidate) else { continue }
            memoisedOrigin = reading.origin
            return reading
        }
        return nil
    }

    @discardableResult
    public func writeBack(_ credentials: OAuthCredentials, to origin: ExternalCredentialOrigin) async -> Bool {
        guard let original = await rawBlob(at: origin),
              let patched = ClaudeCLICredentialBlob.patched(
                  original,
                  with: credentials,
                  isWrapped: origin.isWrapped
              )
        else {
            return false
        }
        switch origin.kind {
        case .keychain:
            // No account means no safe update: `add-generic-password` with the
            // wrong account CREATES a second item instead of replacing the one the
            // CLI reads, leaving the listener with a split, half-dead credential.
            guard let account = origin.account, account.isEmpty == false,
                  let blob = String(bytes: patched, encoding: .utf8)
            else {
                return false
            }
            let result = await security.run(arguments: [
                "add-generic-password",
                "-U",
                "-s", origin.locator,
                "-a", account,
                "-w", blob,
            ])
            return result.didSucceed
        case .file:
            return await files.write(patched, path: origin.locator)
        }
    }
}

// MARK: - Discovery

extension ClaudeCLICredentialStore {
    /// Every place worth looking, in precedence order.
    ///
    /// The file is LAST, so it is reached only when no Keychain candidate yielded
    /// a credential — which is exactly the "Keychain yielded nothing" rule.
    func candidates() async -> [Candidate] {
        var services = await enumerateKeychainServices()
        if services.isEmpty {
            services = [Self.primaryKeychainService]
        }
        return services.map { Candidate.keychain(service: $0) } + [.file(path: filePath)]
    }

    /// Generic-password service names matching the CLI's naming family.
    ///
    /// `dump-keychain` WITHOUT `-d` prints attributes only, so this step never
    /// prompts and never touches secret material.
    func enumerateKeychainServices() async -> [String] {
        let result = await security.run(arguments: ["dump-keychain"])
        guard result.didSucceed else { return [] }
        let found = Self.serviceNames(inDumpOutput: result.standardOutput)
            .filter(Self.isCredentialService)
        guard found.isEmpty == false else { return [] }
        // Primary first: it is the name the current CLI writes, so the common case
        // costs one read rather than a walk through per-account variants.
        let variants = found.subtracting([Self.primaryKeychainService]).sorted()
        return found.contains(Self.primaryKeychainService)
            ? [Self.primaryKeychainService] + variants
            : variants
    }

    /// `Claude Code-credentials`, or that name plus a `-<lowercase hex>` account
    /// discriminator. Anything else in the dump belongs to another application.
    static func isCredentialService(_ name: String) -> Bool {
        if name == primaryKeychainService { return true }
        let prefix = primaryKeychainService + "-"
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return suffix.isEmpty == false && suffix.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    /// Service names out of `security dump-keychain` output.
    ///
    /// Each attribute prints as `"svce"<blob>="value"`, optionally preceded by a
    /// hex rendering (`"svce"<blob>=0x43… "value"`) when the value is not plain
    /// ASCII. The pattern accepts both and captures the quoted form, which is the
    /// only one that round-trips as a service NAME.
    static func serviceNames(inDumpOutput output: String) -> Set<String> {
        let pattern = #""svce"<blob>=(?:0x[0-9A-Fa-f]*\s+)?"((?:[^"\\]|\\.)*)""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(output.startIndex ..< output.endIndex, in: output)
        var names: Set<String> = []
        for match in expression.matches(in: output, range: range) {
            guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: output) else { continue }
            names.insert(String(output[captured]))
        }
        return names
    }
}

// MARK: - Reading

extension ClaudeCLICredentialStore {
    /// Reads and parses one candidate, filling in the envelope shape and — for a
    /// Keychain item — the account name a later write-back needs.
    func read(_ candidate: Candidate) async -> ExternalCredentialReading? {
        switch candidate {
        case let .keychain(service):
            guard let blob = await keychainBlob(service: service),
                  let parsed = ClaudeCLICredentialBlob.parse(blob)
            else {
                return nil
            }
            return await ExternalCredentialReading(
                credentials: parsed.credentials,
                origin: ExternalCredentialOrigin(
                    kind: .keychain,
                    locator: service,
                    account: keychainAccount(service: service),
                    isWrapped: parsed.isWrapped
                )
            )
        case let .file(path):
            guard let blob = await files.read(path: path),
                  let parsed = ClaudeCLICredentialBlob.parse(blob)
            else {
                return nil
            }
            return ExternalCredentialReading(
                credentials: parsed.credentials,
                origin: ExternalCredentialOrigin(kind: .file, locator: path, isWrapped: parsed.isWrapped)
            )
        }
    }

    /// Re-reads an address that already produced a credential once.
    func read(from origin: ExternalCredentialOrigin) async -> ExternalCredentialReading? {
        switch origin.kind {
        case .keychain: await read(.keychain(service: origin.locator))
        case .file: await read(.file(path: origin.locator))
        }
    }

    /// The stored envelope bytes at `origin`, for patching. Never parsed here —
    /// a write-back must patch the ORIGINAL, including fields this app ignores.
    func rawBlob(at origin: ExternalCredentialOrigin) async -> Data? {
        switch origin.kind {
        case .keychain: await keychainBlob(service: origin.locator)
        case .file: await files.read(path: origin.locator)
        }
    }

    private func keychainBlob(service: String) async -> Data? {
        let result = await security.run(arguments: ["find-generic-password", "-s", service, "-w"])
        guard result.didSucceed else { return nil }
        let blob = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard blob.isEmpty == false else { return nil }
        return Data(blob.utf8)
    }

    /// The item's `acct` attribute, read from the NON-secret attribute dump.
    private func keychainAccount(service: String) async -> String? {
        let result = await security.run(arguments: ["find-generic-password", "-s", service])
        guard result.didSucceed else { return nil }
        return Self.accountName(inItemOutput: result.standardOutput)
    }

    /// `"acct"<blob>="value"` from `security find-generic-password` output.
    static func accountName(inItemOutput output: String) -> String? {
        let pattern = #""acct"<blob>=(?:0x[0-9A-Fa-f]*\s+)?"((?:[^"\\]|\\.)*)""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex ..< output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: output)
        else {
            return nil
        }
        let account = String(output[captured])
        return account.isEmpty ? nil : account
    }
}
