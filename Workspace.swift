import ProjectDescription

/// MacAMP workspace — generates "MacAMP.xcworkspace" (git-ignored).
let workspace = Workspace(
    name: "MacAMP",
    projects: [
        "macOS",
        "iOS",
    ]
)
