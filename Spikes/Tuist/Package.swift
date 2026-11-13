// swift-tools-version: 6.0
import PackageDescription

#if TUIST
    import ProjectDescription

    // Keep third-party defaults; we do NOT impose Swift 6 strict concurrency on SFB.
    let packageSettings = PackageSettings(
        productTypes: [:]
    )
#endif

// Standalone dependency set for the audio spike — ONLY SFBAudioEngine, pinned to the
// exact version the main project uses (Tuist/Package.swift in the repo root). This file
// is intentionally separate from the root manifests so the spike stays self-contained.
let package = Package(
    name: "SpikeDependencies",
    dependencies: [
        .package(url: "https://github.com/sbooth/SFBAudioEngine", exact: "0.12.1"),
    ]
)
