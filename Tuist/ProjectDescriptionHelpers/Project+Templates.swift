import ProjectDescription

/// Shared MacAMP constants and Tuist helpers used across every per-platform manifest.
public enum MacAMP {
    /// Non-localized brand / display name. Drives CFBundleDisplayName and PRODUCT_NAME.
    public static let displayName = "MacAMP"

    /// App Group shared by both apps and the widget (now-playing snapshot IPC).
    public static let appGroup = "group.si.macamp.MacAMP"

    public static let macDeploymentTargets: DeploymentTargets = .macOS("14.0")
    public static let iOSDeploymentTargets: DeploymentTargets = .iOS("17.0")

    /// Settings shared by every target: Swift 6 language mode + complete strict concurrency.
    /// No DEVELOPMENT_TEAM or signing identity is hardcoded anywhere.
    public static func sharedSettings(_ extra: SettingsDictionary = [:]) -> Settings {
        var base: SettingsDictionary = [
            "SWIFT_VERSION": "6.0",
            "SWIFT_STRICT_CONCURRENCY": "complete",
        ]
        base.merge(extra) { _, new in new }
        return .settings(base: base)
    }
}
