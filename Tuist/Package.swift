// swift-tools-version: 6.0
import PackageDescription

#if TUIST
    import ProjectDescription

    let packageSettings = PackageSettings(
        // Tuist defaults (.staticFramework). External dependencies keep their own Swift
        // settings — we deliberately do NOT impose Swift 6 strict concurrency on third-party code.
        productTypes: [
            // Shared SwiftUI layer: dynamic framework so macOS/iOS/Widget share one copy.
            "DesignSystem": .framework,
        ]
    )
#endif

let package = Package(
    name: "MacAMPDependencies",
    dependencies: [
        // PlayerCore — the shared, platform-agnostic core (root Package.swift, one dir up).
        .package(path: ".."),
        // AIConnectorKit — the reusable AI provider connector stack. Depends on
        // PlayerCore (kit -> core, never the reverse), so this nested local-path
        // package must resolve alongside the root one. Its OAuth product is
        // linked into macampMac (macOS only, never iOS — see
        // scripts/check-ios-oauth-linkage.sh).
        .package(path: "../AIConnectorKit"),
        // Universal decoders + TagLib metadata. Pinned EXACT per project policy.
        .package(url: "https://github.com/sbooth/SFBAudioEngine", exact: "0.12.1"),
        // SQLite library / playlists (v7.x).
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Sparkle auto-updates — wired to the macOS app target ONLY (see macOS/Project.swift).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        // Model Context Protocol — the one deliberate exception to the no-new-deps
        // posture, because MCP is a WIRE FORMAT with a versioned spec and hand-rolling
        // it means owning a re-implementation that goes silently wrong against every
        // client we do not test. Its `MCP` library target links only swift-system +
        // swift-log + eventsource (swift-nio is in the manifest for the package's own
        // conformance EXECUTABLES and is never linked here). Pinned EXACT per project
        // policy; wired to macampMac ONLY. Full rationale + the spec-version bump note:
        // .omo/notepads/library-chat/decisions.md, W5.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
    ]
)
