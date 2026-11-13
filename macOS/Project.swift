import ProjectDescription
import ProjectDescriptionHelpers

/// Platform-agnostic dependencies of the macOS app: everything from `PlayerCore`
/// plus the macOS-only auto-updater.
///
/// Consumed through ``appDependencies`` below — never linked directly, so the
/// connector products stay visibly separable from the core module graph.
private let sharedAppDependencies: [TargetDependency] = [
    .external(name: "Models"),
    .external(name: "ViewModels"),
    .external(name: "Services"),
    .external(name: "Persistence"),
    .external(name: "AudioEngine"),
    .external(name: "Decoding"),
    .external(name: "Metadata"),
    .external(name: "DSP"),
    .external(name: "Separation"),
    .external(name: "Visualizer"),
    .external(name: "DesignSystem"),
    .external(name: "Lyrics"),
    .external(name: "Artwork"),
    .external(name: "MIDI"),
    .external(name: "GRDB"),
    .external(name: "SFBAudioEngine"),
    // Sparkle is macOS-only — wired here and nowhere else.
    .external(name: "Sparkle"),
]

/// The shipping link set: everything shared, plus all three connector products.
///
/// MacAMP is never distributed through the App Store, so `AIConnectorKitOAuth`
/// — the subscription-OAuth engines behind Claude Subscription and ChatGPT — is
/// linked unconditionally. It used to be withheld from a second, App-Store-safe
/// target, because `SWIFT_ACTIVE_COMPILATION_CONDITIONS` reaches this project's
/// own sources but NOT the code inside an SPM package, making exclusion a
/// LINK-time decision. With one target that distinction no longer buys anything:
/// the paired `ExternalOAuth` buildable folder ships the login UI beside it.
///
/// `MCP` joins them for the same reason `Sparkle` is here and nowhere else: the
/// in-process MCP server (`Sources/MCP/`) is a macOS-shell capability, off by
/// default, and iOS offers no surface that could enable it. `AIConnectorMCP` — the
/// mirror image, MacAMP as a CLIENT of someone else's MCP server — is macOS-only
/// for the same reason, and additionally because reaching a stdio server means
/// spawning a child process, which iOS does not permit at all.
private let appDependencies: [TargetDependency] = sharedAppDependencies + [
    .external(name: "AIConnectorKit"),
    .external(name: "AIConnectorBridge"),
    .external(name: "AIConnectorKitOAuth"),
    .external(name: "MCP"),
    .external(name: "AIConnectorMCP"),
]

/// The three `SU…` keys are Sparkle's auto-update configuration.
///
/// `SUPublicEDKey` is the PUBLIC half of the EdDSA key pair created once by
/// `scripts/setup-sparkle-key.sh` (`--print-public` re-reads it); the private half
/// never leaves the login Keychain. Publishing the public key is the point — every
/// installed copy verifies update archives against it, so replacing it orphans all
/// existing installs.
///
/// The NAME `SUPublicEDKey` is load-bearing and NOT guessable — Sparkle's docs and
/// changelogs have used several plausible-looking spellings over the years, and a
/// wrong one fails SILENTLY at both ends: `SPUUpdater` simply finds no key (updates
/// are never verified) and `generate_appcast` decides signing "isn't required" and
/// emits appcast items with NO `sparkle:edSignature` at all. This repo shipped
/// `SUEdDSAPublicKey` for exactly that reason. Verify the name against the PINNED
/// binary rather than any doc — every key Sparkle reads is a literal in it:
///
///     strings Tuist/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/\
///       macos-arm64_x86_64/Sparkle.framework/Versions/B/Sparkle \
///       | grep -E '^SU[A-Za-z]+$' | sort -u
///
/// (`SUPublicEDKey`, `SUFeedURL`, and `SUEnableAutomaticChecks` all appear;
/// `SUEdDSAPublicKey` appears zero times.) `strings` on `bin/generate_appcast`
/// confirms the same name on the signing side.
///
/// `SUFeedURL` is the production feed on the R2 bucket behind downloads.macamp.si.
/// `scripts/publish-r2.sh` uploads `appcast.xml` to the bucket root and the
/// archives under `releases/`, which must stay in step with `make-appcast.sh`'s
/// default `--download-url-prefix`.
///
/// `SUEnableAutomaticChecks` opts in up front, which also suppresses Sparkle's
/// first-launch "check for updates automatically?" permission prompt.
///
/// `CFBundleShortVersionString` / `CFBundleVersion` MUST stay build-setting
/// references. Tuist's `.extendingDefault` template hardcodes `1.0` / `1`, and a
/// hardcoded plist value cannot be overridden from the command line — measured:
/// `xcodebuild … MARKETING_VERSION=1.2.3` is silently inert against a literal
/// (`.omo/evidence/release-pipeline/todo-10-version-wiring.txt`). This indirection
/// is what lets `build-macamp.sh --app-version <v>` stamp the bundle, which is the
/// only version Sparkle compares — the `.dmg` file name is cosmetic.
private let appInfoPlist: [String: Plist.Value] = [
    "CFBundleDisplayName": "MacAMP",
    "CFBundleName": "MacAMP",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LSApplicationCategoryType": "public.app-category.music",
    "LSMinimumSystemVersion": "14.0",
    "NSHumanReadableCopyright": "Copyright © 2026 Nayden Panchev. Free software under the GNU GPL v3, without warranty. Source: github.com/airnayden/macamp",
    "SUPublicEDKey": "GfbSWrr+xdJgl0vM7tV3s6H+SaaLHelDk/ZbBLm9vLY=",
    "SUFeedURL": "https://downloads.macamp.si/appcast.xml",
    "SUEnableAutomaticChecks": true,
]

/// Reproduces Tuist's former literals exactly, so an un-parameterized build
/// (Xcode, CI, `build-macamp.sh` with no `--app-version`) still yields `1.0 (1)`.
/// A release overrides both on the `xcodebuild` command line, which outranks
/// project *and* target settings — so this is never edited per release.
private let appVersionSettings: SettingsDictionary = [
    "MARKETING_VERSION": "1.0",
    "CURRENT_PROJECT_VERSION": "1",
]

/// Optional Karaoke-mode Core ML model. `Resources/SeparationModel/` is
/// git-ignored and absent in CI + fresh clones — the glob then matches nothing
/// (Tuist tolerates a zero-match resource glob) and the build stays green.
/// When the offline converter (`tools/separation/`) populates it, Xcode compiles
/// `MelBandRoformer.mlpackage` → `MelBandRoformer.mlmodelc` into the bundle,
/// which `CoreMLSeparator` discovers at runtime.
///
/// The pattern is a NON-recursive `*` on purpose: `**` descends INTO the
/// `.mlpackage` wrapper and tries to add its inner `model.mlmodel` as a loose
/// build file, failing `tuist generate` whenever a model is present. `*` keeps
/// the `.mlpackage` opaque so Xcode's CoreML compiler bundles it whole.
private let separationModelResources: ResourceFileElements = [
    "Resources/SeparationModel/*",
]

/// Optional seed binaries for the YouTube downloader. `Resources/DownloaderTools/`
/// is git-ignored and absent on fresh clones and in 12 of the 13 CI jobs — exactly
/// like `Resources/SeparationModel/` above — so every pattern that reaches into it
/// MUST tolerate matching nothing, and each was measured against an empty (and an
/// absent) directory rather than assumed (evidence:
/// `.omo/evidence/task-3-youtube-downloader.txt` for these globs,
/// `.omo/evidence/task-onedir-phase1-youtube-downloader.txt` for the folder
/// reference below).
///
/// ffmpeg and ffprobe are single Mach-O files, so they are copied through a
/// build phase rather than bundled as resources: that lands them outside
/// `Contents/Resources` and code-signs them on copy. The license +
/// written-offer texts ride the `resources:` glob below into
/// `Contents/Resources/` because they are documents, not tools.
///
/// `.executables` resolves to `Contents/MacOS/` — measured, not the
/// `Contents/Executables` the name suggests — so the runtime lookup is
/// `Bundle.main.url(forAuxiliaryExecutable:)`, whose whole job is that folder.
///
/// **yt-dlp is deliberately NOT here.** It ships as a PyInstaller ONE-DIRECTORY
/// tree (see ``downloaderYtDlpTree``), and a `copyFiles` phase flattens: it
/// stages a list of files, not a directory, so the launcher would arrive in
/// `Contents/MacOS/` without its `_internal/` sibling and die at startup with
/// `Failed to load Python shared library '…/_internal/Python'`.
///
/// Each binary is named literally instead of sharing one `*` with the texts: a
/// single wildcard would also drop the three `.txt` files into the executables
/// destination, so the GPL paperwork would ship twice and in the wrong place.
private let downloaderToolExecutables: [CopyFileElement] = [
    .glob(pattern: "Resources/DownloaderTools/ffmpeg", codeSignOnCopy: true),
    .glob(pattern: "Resources/DownloaderTools/ffprobe", codeSignOnCopy: true),
]

/// The yt-dlp PyInstaller one-directory tree, shipped WHOLE.
///
/// `tools/downloader/fetch-download-tools.sh` installs the `yt-dlp_macos.zip`
/// release asset — a `yt-dlp_macos` launcher plus a sibling `_internal/` holding
/// 133 files, 102 of them `.dylib`/`.so` — because the onefile asset re-unpacks
/// ~37 MB into `$TMPDIR/_MEI*` on EVERY exec and never warms up (measured ~13 s
/// per `--version`, against ~0.5 s for this tree).
///
/// `.folderReference` is the only mechanism that preserves that layout: it keeps
/// the directory an opaque blue folder, exactly as the projectM preset/texture
/// packs below need. Flattening the 134 files into the resource group would both
/// explode the build graph and break the launcher, which resolves its Python
/// shared library through the `_internal/` SIBLING at run time.
///
/// **Zero-match tolerance is MEASURED, not assumed** — the same discipline the
/// `copyFiles` globs above were held to, because `Resources/DownloaderTools/` is
/// git-ignored and absent on fresh clones and in 12 of the 13 CI jobs. With the
/// directory ABSENT, `tuist generate --no-open` exits 0, prints one
/// `<path> does not exist` notice, and emits ZERO references into the generated
/// `project.pbxproj` — no dangling file ref, and louder than the silent
/// zero-match `resources:` glob. So no `FileManager` existence guard is needed
/// here. Evidence: `.omo/evidence/task-onedir-phase1-youtube-downloader.txt`.
///
/// Consequence for the runtime lookup: a folder reference lands in
/// `Contents/Resources/`, NOT `Contents/MacOS/`, so `DownloadToolManager`
/// resolves this one through `Bundle.url(forResource:withExtension:)` while
/// ffmpeg/ffprobe keep `url(forAuxiliaryExecutable:)`.
private let downloaderYtDlpTree: ResourceFileElement = .folderReference(
    path: "Resources/DownloaderTools/yt-dlp"
)

/// The GPLv3 license texts and the written source offer that must ship beside the
/// binaries above. Non-recursive `*` for the same reason the model glob is, and
/// narrowed to `.txt` so it can never re-bundle an executable into
/// `Contents/Resources` and give the app two copies of the same tool. Since the
/// onedir migration a bare `*` would additionally match the `yt-dlp/` directory
/// that ``downloaderYtDlpTree`` already ships, doubling ~124 MB of the bundle.
private let downloaderToolResources: ResourceFileElements = [
    "Resources/DownloaderTools/*.txt",
]

/// The optional model, the downloader paperwork and its yt-dlp tree, plus the
/// curated projectM preset + texture packs, which are committed under
/// `Vendor/projectM/` and ship in every build.
///
/// `.folderReference` keeps each pack an opaque blue folder: projectM enumerates
/// them from disk at runtime, so flattening thousands of files into the resource
/// group would both explode the build graph and lose the directory layout it
/// walks.
private let appResources: ResourceFileElements = .resources(
    separationModelResources.resources + downloaderToolResources.resources + [
        downloaderYtDlpTree,
        .folderReference(path: "Vendor/projectM/presets"),
        .folderReference(path: "Vendor/projectM/textures"),
    ]
)

let project = Project(
    name: "macampMac",
    settings: MacAMP.sharedSettings(appVersionSettings),
    targets: [
        // The ONE macOS app. MacAMP is never distributed through the App Store, so
        // there is no second, feature-reduced flavor: this target compiles the
        // projectM (MilkDrop) OpenGL backend and the subscription-OAuth login UI,
        // links + embeds libprojectM-4 (LGPL, dynamically linked), and bundles the
        // curated preset + texture packs. Both `#if` flags below are therefore
        // always true — the conditionals survive in source so a future target that
        // omits either folder still fails loudly rather than silently.
        .target(
            name: "macampMac",
            destinations: .macOS,
            product: .app,
            productName: MacAMP.displayName,
            bundleId: "si.macamp.MacAMP",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: appInfoPlist),
            resources: appResources,
            buildableFolders: [
                "Sources",
                "ProjectM",
                "ExternalOAuth",
            ],
            copyFiles: [
                .frameworks(
                    name: "Embed libprojectM (LGPL, macOS-only)",
                    files: [
                        .glob(
                            pattern: "Vendor/projectM/lib/libprojectM-4.4.dylib",
                            codeSignOnCopy: true
                        ),
                    ]
                ),
                .executables(
                    name: "Embed downloader tools (yt-dlp + ffmpeg, GPLv3)",
                    files: downloaderToolExecutables
                ),
            ],
            entitlements: "macampMac.entitlements",
            dependencies: appDependencies,
            settings: MacAMP.sharedSettings([
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "OTHER_LDFLAGS": [
                    // NO `-lc++` here: the ProjectM `.mm` bridge makes this a clang++
                    // link, and `-stdlib=libc++` already links libc++. An explicit
                    // `-lc++` only duplicates it →
                    // `ld: warning: ignoring duplicate libraries: '-lc++'`.
                    "$(inherited)", "-ObjC",
                    "$(SRCROOT)/Vendor/projectM/lib/libprojectM-4.4.dylib",
                    "-framework", "OpenGL",
                ],
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": ["$(inherited)", "MACAMP_PROJECTM", "MACAMP_EXTERNAL_OAUTH"],
                "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "MACAMP_PROJECTM=1", "GL_SILENCE_DEPRECATION=1"],
                "SWIFT_OBJC_BRIDGING_HEADER": "$(SRCROOT)/ProjectM/MacAMPProjectM-Bridging-Header.h",
                "HEADER_SEARCH_PATHS": [
                    "$(inherited)",
                    "$(SRCROOT)/Vendor/projectM/include",
                    "$(SRCROOT)/ProjectM",
                ],
                "LD_RUNPATH_SEARCH_PATHS": [
                    "$(inherited)",
                    "@executable_path/../Frameworks",
                    "$(SRCROOT)/Vendor/projectM/lib",
                ],
                "GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS": "NO",
            ])
        ),
        .target(
            name: "macampMacTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "si.macamp.MacAMP.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            // A buildable folder, NOT a `sources:` glob. A glob is expanded into an
            // explicit file list at GENERATE time, so a test file added afterwards is
            // absent from the project until someone re-runs `tuist generate` — and an
            // absent test does not fail, it simply never runs, leaving `xcodebuild
            // test` green over a suite that is not there. A buildable folder is a
            // synchronized group Xcode resolves from disk, so new files join forever.
            buildableFolders: ["Tests"],
            dependencies: [
                .target(name: "macampMac"),
                .external(name: "Models"),
                .external(name: "Services"),
                .external(name: "Persistence"),
                .external(name: "AudioEngine"),
                .external(name: "Separation"),
                .external(name: "GRDB"),
                .external(name: "MCP"),
                // NOT `PlayerCoreTestSupport`. MEASURED: linking it from this
                // macOS-only target makes Tuist infer the whole SPM product as
                // macOS-only, and `tuist generate` then hard-fails linting for every
                // iOS-capable PlayerCore test target that depends on it (~20 of them).
                // A `condition: .when([.macos])` on the edge does NOT help. Shell-side
                // suites therefore script their own doubles — see
                // `ScriptedOutputDeviceController`.
            ]
        ),
        // Ad-hoc signing is scoped to THIS UITest target only; app/widget targets are
        // untouched. `xcodebuild test` must sign the host app, whose App-Group
        // entitlement would demand a provisioning profile no team can satisfy here — so
        // the gate command strips entitlements at INVOCATION scope
        // (`CODE_SIGN_ENTITLEMENTS= CODE_SIGNING_REQUIRED=NO`), affecting nothing for
        // dev/release builds. See `.omo/evidence/task-13-macamp-app-optimization.txt`.
        .target(
            name: "macampMacUITests",
            destinations: .macOS,
            product: .uiTests,
            bundleId: "si.macamp.MacAMP.uitests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            buildableFolders: ["UITests"],
            dependencies: [
                .target(name: "macampMac"),
            ],
            settings: MacAMP.sharedSettings([
                "CODE_SIGN_IDENTITY": "-",
                "CODE_SIGN_STYLE": "Manual",
                "CODE_SIGNING_REQUIRED": "NO",
                "CODE_SIGNING_ALLOWED": "YES",
            ])
        ),
    ]
)
