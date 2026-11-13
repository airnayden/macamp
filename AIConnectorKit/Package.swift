// swift-tools-version: 6.0
// AIConnectorKit — MacAMP's reusable AI provider connector stack.
//
// Swift 6 language mode (complete strict concurrency) is implied by tools-version 6.0.
// Three targets, split by what each is allowed to depend on:
//
//   AIConnectorKit       protocols, transports, connectors. Foundation / CryptoKit /
//                        Security ONLY — no AppKit, no UIKit, and nothing from
//                        PlayerCore, so the whole target lifts into another app
//                        unchanged. `scripts/check-playercore-portability.sh` scans
//                        AIConnectorKit/Sources alongside PlayerCore/Sources.
//   AIConnectorBridge    the MacAMP-specific half: seam conformers + canonical
//                        schema. This is the ONLY target that may touch PlayerCore.
//   AIConnectorKitOAuth  subscription-OAuth engines (Claude, ChatGPT). Kept a
//                        SEPARATE product, not folded into the kit: an embedder that
//                        wants only API-key providers must be able to leave the OAuth
//                        engines — and their consumer-login surface — unlinked, which
//                        is a LINK-time choice a compile flag cannot express for
//                        package code. MacAMP's one macOS app links all three.
//   AIConnectorMCP       the MCP CLIENT half: talking to EXTERNAL MCP servers.
//                        Separate from the core for the same link-time reason as the
//                        OAuth product — it is the only target that pulls in the MCP
//                        Swift SDK, and an embedder that wants plain provider
//                        connectors must be able to leave the whole protocol stack
//                        unlinked. Depends on the CORE target because the projection
//                        it exists to perform answers in ``AITool``, which lives
//                        there. It must NEVER depend on PlayerCore.
//
// Dependency direction is kit -> PlayerCore, never the reverse: the root
// `Package.swift` MUST NOT reference this package.
import PackageDescription

let package = Package(
    name: "AIConnectorKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "AIConnectorKit", targets: ["AIConnectorKit"]),
        .library(name: "AIConnectorBridge", targets: ["AIConnectorBridge"]),
        .library(name: "AIConnectorKitOAuth", targets: ["AIConnectorKitOAuth"]),
        .library(name: "AIConnectorMCP", targets: ["AIConnectorMCP"]),
        // A TEST FIXTURE, never linked into an app. `MCPProcessTransport` spawns a
        // child process, and the in-memory transport its sibling tests use forks
        // nothing — so the one counterparty that can exercise pipe wiring, stderr
        // drain and termination is a real program this repo builds and controls.
        //
        // NOTHING MAY DEPEND ON THIS TARGET — see the note above the test target.
        .executable(name: "MCPFixtureServer", targets: ["MCPFixtureServer"]),
    ],
    dependencies: [
        // PlayerCore lives one directory up. The explicit `name:` is MANDATORY.
        // SwiftPM derives a path dependency's IDENTITY from the directory basename
        // — here `macamp` — NOT from the manifest's declared `name` ("PlayerCore",
        // root Package.swift:10). With a bare `.package(path: "..")` every product
        // reference below would have to read `package: "macamp"`, which reads like a
        // typo and breaks the moment the checkout directory is renamed. Naming the
        // dependency pins the token used by `.product(name:package:)` instead.
        .package(name: "PlayerCore", path: ".."),
        // The MCP Swift SDK — this package's first DIRECT REMOTE dependency. The
        // ~21 packages already in `Package.resolved` arrive TRANSITIVELY through
        // `PlayerCore` (GRDB, SFBAudioEngine and its binary codecs), so this is the
        // first entry an offline `--force-resolved-versions` resolve must satisfy
        // from this manifest's own line. Pinned EXACT, matching `Tuist/Package.swift`
        // — `scripts/check-mcp-pin.sh` fails the build if the two ever disagree.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
    ],
    targets: [
        // Reusable core. No PlayerCore dependency — deliberately empty deps.
        .target(name: "AIConnectorKit"),
        .target(
            name: "AIConnectorBridge",
            dependencies: [
                "AIConnectorKit",
                .product(name: "Services", package: "PlayerCore"),
            ]
        ),
        .target(
            name: "AIConnectorKitOAuth",
            dependencies: ["AIConnectorKit"]
        ),
        // `MCP` is the SDK's library product; `swift-sdk` is the package identity
        // SwiftPM derives from the URL's last path component, NOT the manifest's
        // declared name.
        .target(
            name: "AIConnectorMCP",
            dependencies: [
                "AIConnectorKit",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "AIConnectorKitTests",
            dependencies: ["AIConnectorKit"],
            // Fixtures are loaded via #filePath, not Bundle.module — not a build
            // input. Same convention as the root Package.swift's `Fixtures` dirs.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "AIConnectorBridgeTests",
            dependencies: ["AIConnectorBridge"]
        ),
        .testTarget(
            name: "AIConnectorKitOAuthTests",
            dependencies: ["AIConnectorKitOAuth"]
        ),
        .executableTarget(
            name: "MCPFixtureServer",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        // `MCPFixtureServer` IS DELIBERATELY ABSENT FROM THESE DEPENDENCIES, and
        // adding it breaks `tuist generate` for the whole workspace. Tuist's package
        // loader DISCARDS executable targets of an external package ("Target
        // MCPFixtureServer of type executable ignored"), then fails hard on any
        // dependency edge pointing at the target it just discarded:
        //     ✖ Couldn't find target 'MCPFixtureServer' at '…/AIConnectorKit'
        // The root package's `macamp-cli` survives the same discarding for exactly
        // one reason — nothing depends on it either.
        //
        // The edge is also UNNECESSARY, which is the part worth measuring rather
        // than assuming: `swift test` runs `swift build --build-tests`, and that
        // builds every target of the ROOT package, not merely the test graph.
        // Verified by deleting the binary and rebuilding: "[15/92] Linking
        // MCPFixtureServer" with no edge present. The suite resolves it from the
        // bin directory it lands in.
        .testTarget(
            name: "AIConnectorMCPTests",
            dependencies: ["AIConnectorMCP"]
        ),
    ]
)
