import ProjectDescription

/// Standalone Tuist config for the THROWAWAY Phase 0 audio spike.
///
/// This makes `Spikes/` its own Tuist root so generating/​installing here never
/// touches the repo-root project (root `Workspace.swift` lists only macOS/iOS/Widget,
/// and `tuist … --path Spikes` resolves config from THIS file).
let tuist = Tuist(
    project: .tuist(
        compatibleXcodeVersions: .all
    )
)
