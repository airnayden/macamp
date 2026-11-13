// AppEnvironment+AI — the gated local-AI object graph (iOS).
//
// iOS ships the read-only half of the feature: generator-backed playlists the
// listener opens and plays like any other. There is no assistant, no proposal
// preview, no organisation, no hygiene and no analysis pass on this shell, so the
// stack holds exactly one service — the rest of the graph would be unreachable
// weight. FoundationModels is therefore never referenced here at all, which is why
// this file needs no `#if canImport` island (the macOS twin has one).
//
// The gating contract is identical to macOS: master toggle off ⇒ ``ai`` is `nil`
// and nothing exists to read the database or schedule work; toggling it back on
// rebuilds in place through `withObservationTracking`, never a timer. Switching off
// never deletes an already-materialised playlist.
//
// TWO macOS seams are deliberately absent here, and both are absences of a TRIGGER
// rather than of the capability:
//
//  * NO profile-switch reseat. This shell is Guest-fixed — it builds a `ProfileService`
//    only so the shared view models can be scoped, and offers no surface that calls
//    `switchTo`, so `onActiveProfileChanged` can never fire. `rebuildAI` already reads
//    the active profile, so the day iOS grows a profile switcher the wiring is one
//    chained closure (`AppEnvironment+AI.swift` on macOS is the template) — until then
//    it would be dead code guarding an event that does not exist.
//  * NO app-launch refresh. `refreshIfStale` has exactly one caller on iOS, the Auto
//    Mixes section's own `.task`, which is the whole read-only surface: a launch that
//    never opens Playlists has nothing to refresh FOR, and a launch that does opens it
//    within the same breath.
import Foundation
import Observation
import Persistence
import Services
import ViewModels

extension AppEnvironment {
    /// The AI services the iOS shell exposes, built as one unit or not at all.
    struct AIStack {
        /// Materialised auto-mixes with lazy TTL refresh (no timers).
        let generatedPlaylists: GeneratedPlaylistService
        /// The read-only projection the Playlists screen's Auto Mixes section
        /// renders. It lives in the stack — not in the view — so it is created and
        /// destroyed with the service it reads, and so the master toggle keeps
        /// costing exactly nothing when it is off.
        let autoMixList: AutoMixListViewModel
    }

    /// Builds the AI graph, or `nil` when the master toggle is off.
    static func makeAI(settings: AppSettings, database: AppDatabase, profileId: Int64) -> AIStack? {
        guard settings.intelligenceEnabled else { return nil }
        let generatedPlaylists = GeneratedPlaylistService(
            database,
            generator: MixGeneratorService(database),
            aiSettings: settings
        )
        return AIStack(
            generatedPlaylists: generatedPlaylists,
            autoMixList: AutoMixListViewModel(service: generatedPlaylists, activeProfileId: profileId)
        )
    }

    /// Builds the AI graph for `settings` and keeps it in step with the master toggle.
    func connectAI(settings: AppSettings) {
        rebuildAI(settings: settings)
        observeIntelligenceToggle(settings: settings)
    }

    /// Constructs or tears down the graph to match the master toggle.
    func rebuildAI(settings: AppSettings) {
        intelligence = Self.makeAI(
            settings: settings,
            database: database,
            profileId: profileService.activeProfile.id ?? ProfileRecord.guestID
        )
    }

    /// Re-arms itself on every change. `onChange` fires BEFORE the write lands,
    /// hence the main-actor hop before re-reading.
    private func observeIntelligenceToggle(settings: AppSettings) {
        withObservationTracking {
            _ = settings.intelligenceEnabled
        } onChange: { [weak self, weak settings] in
            Task { @MainActor in
                guard let self, let settings else { return }
                self.rebuildAI(settings: settings)
                self.observeIntelligenceToggle(settings: settings)
            }
        }
    }
}
