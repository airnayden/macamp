// Hermetic proof of Claude Code CLI credential reuse.
//
// Every claim the feature makes is asserted here against fakes: the discovery
// ORDER (Keychain before file, primary service before variants), both envelope
// shapes, the MCP-only skip, and — the one that can damage another application if
// it is wrong — a write-back that patches only the rotating fields and preserves
// the shape it found.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

@Suite("ClaudeCLIDiscoveryTests")
struct ClaudeCLIDiscoveryTests {
    @Test("The Keychain wins over the credentials file")
    func keychainOutranksTheFile() async throws {
        let security = FakeSecurityCommand(
            dump: SecurityCommandResult(
                exitCode: 0,
                standardOutput: ClaudeCLIFixture.dumpOutput(services: [ClaudeCLICredentialStore
                        .primaryKeychainService])
            ),
            blobs: [ClaudeCLICredentialStore.primaryKeychainService: ClaudeCLIFixture.wrappedBlob()],
            accounts: [
                ClaudeCLICredentialStore
                    .primaryKeychainService: ClaudeCLIFixture
                    .itemOutput(service: ClaudeCLICredentialStore.primaryKeychainService),
            ]
        )
        let files = FakeCredentialFiles(contents: [ClaudeCLIFixture.filePath: ClaudeCLIFixture.flatBlob()])
        let store = ClaudeCLICredentialStore(security: security, files: files, filePath: ClaudeCLIFixture.filePath)

        let reading = try #require(await store.load())

        #expect(reading.credentials.accessToken == ClaudeCLIFixture.accessToken)
        #expect(reading.origin.kind == .keychain)
        #expect(reading.origin.isWrapped)
        #expect(reading.origin.account == ClaudeCLIFixture.account)
    }

    @Test("The file is read only when the Keychain yields nothing")
    func fileIsTheFallback() async throws {
        let security = FakeSecurityCommand(dump: SecurityCommandResult(exitCode: 0, standardOutput: ""))
        let files = FakeCredentialFiles(contents: [ClaudeCLIFixture.filePath: ClaudeCLIFixture.flatBlob()])
        let store = ClaudeCLICredentialStore(security: security, files: files, filePath: ClaudeCLIFixture.filePath)

        let reading = try #require(await store.load())

        #expect(reading.credentials.accessToken == ClaudeCLIFixture.fileAccessToken)
        #expect(reading.credentials.subscriptionType == "pro")
        #expect(reading.origin.kind == .file)
        #expect(reading.origin.isWrapped == false)
        #expect(reading.origin.account == nil)
    }

    @Test("A failing dump falls back to probing the primary service directly")
    func dumpFailureFallsBackToTheKnownName() async throws {
        // A locked or hardened keychain makes enumeration fail. The primary name
        // is not a discovery RESULT — it is a constant — so a failed dump must not
        // cost the listener their reused session.
        let security = FakeSecurityCommand(
            dump: SecurityCommandResult(exitCode: 1, standardError: "SecKeychainCopySearchList failed"),
            blobs: [ClaudeCLICredentialStore.primaryKeychainService: ClaudeCLIFixture.wrappedBlob()],
            accounts: [
                ClaudeCLICredentialStore
                    .primaryKeychainService: ClaudeCLIFixture
                    .itemOutput(service: ClaudeCLICredentialStore.primaryKeychainService),
            ]
        )
        let store = ClaudeCLICredentialStore(
            security: security,
            files: FakeCredentialFiles(),
            filePath: ClaudeCLIFixture.filePath
        )

        let reading = try #require(await store.load())

        #expect(reading.origin.locator == ClaudeCLICredentialStore.primaryKeychainService)
        #expect(await security.values(after: "-s") == [ClaudeCLICredentialStore.primaryKeychainService,
                                                       ClaudeCLICredentialStore.primaryKeychainService])
    }

    @Test("An MCP-only entry is skipped and the real login behind it is found")
    func mcpOnlyEntriesAreSkipped() async throws {
        let primary = ClaudeCLICredentialStore.primaryKeychainService
        let security = FakeSecurityCommand(
            dump: SecurityCommandResult(
                exitCode: 0,
                standardOutput: ClaudeCLIFixture.dumpOutput(services: [primary, ClaudeCLIFixture.variantService])
            ),
            blobs: [
                primary: ClaudeCLIFixture.mcpOnlyBlob,
                ClaudeCLIFixture.variantService: ClaudeCLIFixture.wrappedBlob(),
            ],
            accounts: [ClaudeCLIFixture.variantService: ClaudeCLIFixture
                .itemOutput(service: ClaudeCLIFixture.variantService)]
        )
        let store = ClaudeCLICredentialStore(
            security: security,
            files: FakeCredentialFiles(),
            filePath: ClaudeCLIFixture.filePath
        )

        let reading = try #require(await store.load())

        #expect(reading.origin.locator == ClaudeCLIFixture.variantService)
        #expect(reading.credentials.accessToken == ClaudeCLIFixture.accessToken)
    }

    @Test("Nothing anywhere reads as no reusable session, not as an error")
    func absentEverywhereIsNil() async {
        let store = ClaudeCLICredentialStore(
            security: FakeSecurityCommand(),
            files: FakeCredentialFiles(),
            filePath: ClaudeCLIFixture.filePath
        )

        #expect(await store.load() == nil)
    }

    @Test("Only the CLI's own service-name family is a candidate")
    func serviceNameFamilyIsRecognisedExactly() {
        #expect(ClaudeCLICredentialStore.isCredentialService("Claude Code-credentials"))
        #expect(ClaudeCLICredentialStore.isCredentialService("Claude Code-credentials-9f2a1c"))
        #expect(ClaudeCLICredentialStore.isCredentialService("Claude Code-credentials-9F2A1C") == false)
        #expect(ClaudeCLICredentialStore.isCredentialService("Claude Code-credentials-not-hex") == false)
        #expect(ClaudeCLICredentialStore.isCredentialService("Claude Code-credentials-") == false)
        #expect(ClaudeCLICredentialStore.isCredentialService("Some Other App-credentials") == false)
    }

    @Test("Service names are parsed out of a dump, quoted and hex-prefixed alike")
    func dumpParsingHandlesBothAttributeRenderings() {
        let output = """
            "svce"<blob>="Claude Code-credentials"
            "svce"<blob>=0x436C617564 "Claude Code-credentials-9f2a1c"
            "svce"<blob>="Xcode"
        """

        let names = ClaudeCLICredentialStore.serviceNames(inDumpOutput: output)

        #expect(names == ["Claude Code-credentials", "Claude Code-credentials-9f2a1c", "Xcode"])
    }

    @Test("The account name is read from the non-secret attribute dump")
    func accountNameIsParsed() {
        let output = ClaudeCLIFixture.itemOutput(service: ClaudeCLICredentialStore.primaryKeychainService)

        #expect(ClaudeCLICredentialStore.accountName(inItemOutput: output) == ClaudeCLIFixture.account)
        #expect(ClaudeCLICredentialStore.accountName(inItemOutput: "class: \"genp\"") == nil)
    }
}

@Suite("ClaudeCLIBlobTests")
struct ClaudeCLIBlobTests {
    @Test("Both envelope shapes parse, and the shape is reported")
    func bothShapesParse() throws {
        let wrapped = try #require(ClaudeCLICredentialBlob.parse(Data(ClaudeCLIFixture.wrappedBlob().utf8)))
        #expect(wrapped.isWrapped)
        #expect(wrapped.credentials.accessToken == ClaudeCLIFixture.accessToken)
        #expect(wrapped.credentials.subscriptionType == "max")
        #expect(wrapped.credentials.scopes == ["user:profile", "user:inference"])

        let flat = try #require(ClaudeCLICredentialBlob.parse(Data(ClaudeCLIFixture.flatBlob().utf8)))
        #expect(flat.isWrapped == false)
        #expect(flat.credentials.refreshToken == ClaudeCLIFixture.fileRefreshToken)
    }

    @Test("expiresAt is JavaScript MILLISECONDS, not POSIX seconds")
    func expiryIsMilliseconds() throws {
        // Reading it as seconds puts expiry ~55,000 years out, which makes every
        // token look permanently fresh and converts the first 401 into a hard
        // logout instead of a refresh.
        let parsed = try #require(ClaudeCLICredentialBlob.parse(Data(ClaudeCLIFixture.wrappedBlob().utf8)))

        #expect(parsed.credentials.expiresAt == ClaudeCLIFixture.expiry)
        #expect(parsed.credentials.expiresAt.timeIntervalSince1970 < 2_000_000_000)
    }

    @Test("An unusable envelope is nil rather than a throw")
    func unusableEnvelopesAreNil() {
        #expect(ClaudeCLICredentialBlob.parse(Data("not json".utf8)) == nil)
        #expect(ClaudeCLICredentialBlob.parse(Data("{}".utf8)) == nil)
        #expect(ClaudeCLICredentialBlob.parse(Data(ClaudeCLIFixture.mcpOnlyBlob.utf8)) == nil)
        #expect(ClaudeCLICredentialBlob.parse(Data("{\"accessToken\":\"a\"}".utf8)) == nil)
    }

    @Test("An MCP grant is skipped by name, not merely by a missing token")
    func mcpOnlyIsSkippedByName() throws {
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(ClaudeCLIFixture.mcpOnlyBlob.utf8)) as? [String: Any]
        )

        #expect(ClaudeCLICredentialBlob.isMCPOnly(root))
    }

    @Test("Patching replaces the three rotating fields and nothing else")
    func patchingIsFieldScoped() throws {
        let rotated = OAuthCredentials(
            accessToken: ClaudeCLIFixture.rotatedAccessToken,
            refreshToken: ClaudeCLIFixture.rotatedRefreshToken,
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            subscriptionType: "pro",
            scopes: ["user:profile"]
        )
        let patched = try #require(ClaudeCLICredentialBlob.patched(
            Data(ClaudeCLIFixture.wrappedBlob().utf8),
            with: rotated,
            isWrapped: true
        ))
        let root = try #require(try JSONSerialization.jsonObject(with: patched) as? [String: Any])
        let node = try #require(root[ClaudeCLICredentialBlob.wrapperKey] as? [String: Any])

        #expect(node["accessToken"] as? String == ClaudeCLIFixture.rotatedAccessToken)
        #expect(node["refreshToken"] as? String == ClaudeCLIFixture.rotatedRefreshToken)
        #expect(node["expiresAt"] as? Int == 1_800_000_000_000)
        // Untouched: the tier the CLI recorded, the scopes, a field this app has
        // never heard of, and a sibling of the wrapper key.
        #expect(node["subscriptionType"] as? String == "max")
        #expect(node["scopes"] as? [String] == ["user:profile", "user:inference"])
        #expect(node["unknownFutureField"] as? String == "keep-me")
        #expect(root["otherTopLevelKey"] as? Int == 42)
    }

    @Test("A shape mismatch refuses the patch rather than rewriting the envelope")
    func shapeMismatchRefusesThePatch() {
        let credentials = OAuthCredentials(
            accessToken: "test-token-cli-x",
            refreshToken: "test-token-cli-y",
            expiresAt: Date(timeIntervalSince1970: 1)
        )
        // Rewriting a flat blob as wrapped (or the reverse) signs the OWNING
        // application out — the one outcome reuse must never produce.
        #expect(ClaudeCLICredentialBlob.patched(
            Data(ClaudeCLIFixture.flatBlob().utf8),
            with: credentials,
            isWrapped: true
        ) == nil)
        #expect(ClaudeCLICredentialBlob.patched(
            Data(ClaudeCLIFixture.wrappedBlob().utf8),
            with: credentials,
            isWrapped: false
        ) == nil)
    }
}

@Suite("ClaudeCLIWriteBackTests")
struct ClaudeCLIWriteBackTests {
    @Test("A Keychain write-back updates in place, preserving the wrapped shape")
    func keychainWriteBackPreservesShape() async throws {
        let primary = ClaudeCLICredentialStore.primaryKeychainService
        let security = FakeSecurityCommand(
            dump: SecurityCommandResult(
                exitCode: 0,
                standardOutput: ClaudeCLIFixture.dumpOutput(services: [primary])
            ),
            blobs: [primary: ClaudeCLIFixture.wrappedBlob()],
            accounts: [primary: ClaudeCLIFixture.itemOutput(service: primary)]
        )
        let store = ClaudeCLICredentialStore(
            security: security,
            files: FakeCredentialFiles(),
            filePath: ClaudeCLIFixture.filePath
        )
        let reading = try #require(await store.load())
        var rotated = reading.credentials
        rotated.accessToken = ClaudeCLIFixture.rotatedAccessToken
        rotated.refreshToken = ClaudeCLIFixture.rotatedRefreshToken

        #expect(await store.writeBack(rotated, to: reading.origin))

        let writes = await security.writes
        #expect(writes.count == 1)
        #expect(writes.first?.service == primary)
        #expect(writes.first?.account == ClaudeCLIFixture.account)
        // `-U` is what makes this an UPDATE. Without it the command creates a
        // second item and the CLI keeps reading the dead one.
        #expect(await security.invocations.last?.contains("-U") == true)

        let stored = try #require(await security.blob(for: primary))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
        let node = try #require(root[ClaudeCLICredentialBlob.wrapperKey] as? [String: Any])
        #expect(node["accessToken"] as? String == ClaudeCLIFixture.rotatedAccessToken)
        #expect(node["unknownFutureField"] as? String == "keep-me")
    }

    @Test("A file write-back preserves the flat shape")
    func fileWriteBackPreservesShape() async throws {
        let files = FakeCredentialFiles(contents: [ClaudeCLIFixture.filePath: ClaudeCLIFixture.flatBlob()])
        let store = ClaudeCLICredentialStore(
            security: FakeSecurityCommand(),
            files: files,
            filePath: ClaudeCLIFixture.filePath
        )
        let reading = try #require(await store.load())
        var rotated = reading.credentials
        rotated.accessToken = ClaudeCLIFixture.rotatedAccessToken

        #expect(await store.writeBack(rotated, to: reading.origin))

        let stored = try #require(await files.text(at: ClaudeCLIFixture.filePath))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
        #expect(root[ClaudeCLICredentialBlob.wrapperKey] == nil)
        #expect(root["accessToken"] as? String == ClaudeCLIFixture.rotatedAccessToken)
        #expect(root["legacyFlag"] as? Bool == true)
    }

    @Test("A Keychain origin with no discovered account refuses the write-back")
    func missingAccountRefusesTheWriteBack() async {
        let primary = ClaudeCLICredentialStore.primaryKeychainService
        let security = FakeSecurityCommand(blobs: [primary: ClaudeCLIFixture.wrappedBlob()])
        let store = ClaudeCLICredentialStore(
            security: security,
            files: FakeCredentialFiles(),
            filePath: ClaudeCLIFixture.filePath
        )
        let origin = ExternalCredentialOrigin(kind: .keychain, locator: primary, account: nil, isWrapped: true)
        let credentials = OAuthCredentials(
            accessToken: "test-token-cli-x",
            refreshToken: "test-token-cli-y",
            expiresAt: Date(timeIntervalSince1970: 1)
        )

        #expect(await store.writeBack(credentials, to: origin) == false)
        #expect(await security.writes.isEmpty)
    }
}
