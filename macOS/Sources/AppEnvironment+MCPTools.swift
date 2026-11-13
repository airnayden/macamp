// AppEnvironment+MCPTools — keeping the cloud tier's tool list in step with the
// listener's own MCP servers.
//
// The mirror image of `AppEnvironment+MCP.swift`: that file composes MacAMP as a
// SERVER of its library; this one composes MacAMP as a CLIENT of somebody else's.
//
// ── WHY THE SUPPLY IS NOT INSIDE `makeAI` ────────────────────────────────────
//
// The AI graph is REPLACED on a master-toggle flip, a provider change, a model
// change and a profile switch. An `MCPToolSupply` rebuilt on each of those would
// terminate and respawn every configured CHILD PROCESS four ways for reasons that
// have nothing to do with MCP — so the supply is owned by ``AppEnvironment`` and
// reaches the graph through a closure, exactly as ``externalAccess`` does.
//
// ── THE REBUILD IS THE POINT, NOT AN OPTIMISATION ────────────────────────────
//
// `ConnectorChatEngine` takes its tool list at `init`, and `LibraryChatViewModel`
// CACHES the engine it minted. So a server the listener has just switched off would
// keep answering for the rest of the conversation unless the graph is replaced
// under it — the tool closures are still live, still namespaced, still callable.
// ``refresh()`` therefore reports whether the published list actually changed, and
// only then is the graph rebuilt: a settings write that left the usable set alone
// costs no teardown, and one that did not is guaranteed to reach the next turn.
//
// The observation is the shape `observeIntelligenceToggle` established — re-armed
// on every change, main-actor hop before re-reading, because `onChange` fires
// BEFORE the write lands.
import Foundation
import Observation

extension AppEnvironment {
    /// Builds the supply, projects what is already configured, and keeps both in
    /// step with the listener's MCP settings.
    func connectMCPTools(settings: AppSettings) {
        mcpTools = MCPToolSupply.live(settings: settings)
        refreshMCPTools(settings: settings)
        observeMCPServers(settings: settings)
    }

    /// Re-projects the usable servers' tools, rebuilding the conversation graph only
    /// if the published list really moved.
    ///
    /// Asynchronous and unawaited by design: reaching a server is a `tools/list`
    /// round trip, and neither app launch nor a Preferences write may block on one.
    /// A listener with nothing configured never gets past `refresh()`'s first guard,
    /// so the whole path costs nothing at all in the default install.
    private func refreshMCPTools(settings: AppSettings) {
        guard let supply = mcpTools else { return }
        Task { @MainActor [weak self] in
            guard await supply.refresh(), let self else { return }
            rebuildAI(settings: settings)
        }
    }

    private func observeMCPServers(settings: AppSettings) {
        withObservationTracking {
            // Both halves of the grant, for the reason `MCPServerDescriptor.isUsable`
            // reads both: consent is recorded in its own set, so a server enabled
            // before its disclosure was accepted becomes usable on the CONSENT write
            // and on no other.
            _ = settings.mcpServers
            _ = settings.mcpConsentedServerIDs
        } onChange: { [weak self, weak settings] in
            Task { @MainActor in
                guard let self, let settings else { return }
                self.refreshMCPTools(settings: settings)
                self.observeMCPServers(settings: settings)
            }
        }
    }
}
