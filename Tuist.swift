import ProjectDescription

/// MacAMP Tuist configuration.
///
/// Swift 6 language mode and complete strict concurrency are applied to every generated
/// target via `MacAMP.sharedSettings()` in
/// Tuist/ProjectDescriptionHelpers/Project+Templates.swift
/// (SWIFT_VERSION = 6.0, SWIFT_STRICT_CONCURRENCY = complete).
///
/// The config-level `swiftVersion` field is deprecated in Tuist 4.x, so the Swift 6
/// policy is enforced through target build settings instead of here.
let tuist = Tuist(
    project: .tuist(
        compatibleXcodeVersions: .all
    )
)
