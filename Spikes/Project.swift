import ProjectDescription

/// THROWAWAY Phase 0 audio spike — a single multiplatform (macOS + iOS) app that
/// proves SFBAudioEngine decode → 10-band AVAudioUnitEQ → tap → SPSC ring buffer →
/// vDSP FFT → Metal spectrum. Standalone; references nothing in PlayerCore.
///
/// Deployment is macOS 15 / iOS 18 (newer than the app's macOS 14 / iOS 17) only so the
/// spike can use the first-party `Synchronization.Atomic` for the lock-free ring buffer;
/// the production core would use swift-atomics for the same pattern on its lower floor.
let project = Project(
    name: "Spike",
    targets: [
        .target(
            name: "SpikeAudio",
            destinations: [.mac, .iPhone, .iPad],
            product: .app,
            bundleId: "com.example.macamp.spike",
            deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": .string("SpikeAudio"),
                "UILaunchScreen": .dictionary([:]),
                // iOS background audio so a tap keeps firing if backgrounded; ignored on macOS.
                "UIBackgroundModes": .array([.string("audio")]),
            ]),
            sources: [
                "SpikeAudio/*.swift",
            ],
            resources: [
                "SpikeAudio/Resources/**",
            ],
            dependencies: [
                .external(name: "SFBAudioEngine"),
            ],
            settings: .settings(base: [
                "SWIFT_VERSION": "6.0",
                "SWIFT_STRICT_CONCURRENCY": "complete",
                // Ad-hoc signing so the app + embedded SFB frameworks run with no team,
                // on both the local Mac and the iOS simulator.
                "CODE_SIGN_IDENTITY": "-",
                "CODE_SIGN_STYLE": "Manual",
                "MARKETING_VERSION": "0.1",
                "CURRENT_PROJECT_VERSION": "1",
                // SFBAudioEngine linkage (it is a STATIC framework here):
                //  -lc++  : CSFBAudioEngine is C++, so a pure-Swift app must link libc++.
                //  -ObjC  : its decoder subclasses self-register at ObjC load time; without
                //           this the linker dead-strips them and SFB reports
                //           "could not determine the file type" for FLAC/MP3.
                "OTHER_LDFLAGS": ["$(inherited)", "-lc++", "-ObjC"],
            ])
        ),
    ]
)
