import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: "macampiOS",
    settings: MacAMP.sharedSettings(),
    targets: [
        .target(
            name: "macampiOS",
            destinations: .iOS,
            product: .app,
            productName: MacAMP.displayName,
            bundleId: "si.macamp.MacAMP.ios",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDisplayName": "MacAMP",
                    "CFBundleName": "MacAMP",
                    "NSHumanReadableCopyright": "Copyright © 2026 Nayden Panchev. Free software under the GNU GPL v3, without warranty. Source: github.com/airnayden/macamp",
                    // Version / build number (App Store required).
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "1",
                    "UILaunchScreen": [:],
                    // Background audio playback (Task 34): keep rendering when backgrounded.
                    "UIBackgroundModes": ["audio"],
                    // Required device capabilities — arm64 only (no 32-bit support).
                    "UIRequiredDeviceCapabilities": ["arm64"],
                    // Export compliance: app uses no non-exempt encryption (Task 39).
                    "ITSAppUsesNonExemptEncryption": false,
                ]
            ),
            buildableFolders: [
                "Sources",
            ],
            entitlements: "macampiOS.entitlements",
            dependencies: [
                .external(name: "Models"),
                .external(name: "ViewModels"),
                .external(name: "Services"),
                .external(name: "Persistence"),
                .external(name: "AudioEngine"),
                .external(name: "Decoding"),
                .external(name: "Metadata"),
                .external(name: "DSP"),
                .external(name: "Visualizer"),
                .external(name: "DesignSystem"),
                .external(name: "Lyrics"),
                .external(name: "Artwork"),
                .external(name: "MIDI"),
                .external(name: "GRDB"),
                .external(name: "SFBAudioEngine"),
                // No Sparkle on iOS — updates ship via the App Store.
            ],
            settings: MacAMP.sharedSettings([
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "OTHER_LDFLAGS": ["$(inherited)", "-ObjC", "-lc++"],
            ])
        ),
        .target(
            name: "macampiOSTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "si.macamp.MacAMP.ios.tests",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .default,
            buildableFolders: ["Tests"],
            dependencies: [
                .target(name: "macampiOS"),
                .external(name: "Services"),
                .external(name: "Persistence"),
            ]
        ),
    ]
)
