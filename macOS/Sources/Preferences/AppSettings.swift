// AppSettings — the macOS shell's user-preference store.
//
// Every value the Preferences window edits lives here, persisted to `UserDefaults`
// (NOT the library database — transient UI/preference state must never touch the
// GRDB store). The type is `@Observable` so SwiftUI panes bind to it with
// `@Bindable`, and one shared instance is injected through the environment, so the
// Preferences window and the state-restoration controller read the same values.
//
// Each stored property writes through to `UserDefaults` in its `didSet`; the
// initializer hydrates from `UserDefaults` (assignments in `init` do not fire
// `didSet`, so hydration never redundantly writes back). `UserDefaults` is not
// `Sendable`, but this type is `@MainActor`, so holding the resolved suite is safe.
// A volatile suite can be injected for previews/tests.
//
// This is app-shell code: importing SwiftUI/AppKit-adjacent types here is fine
// (the AppKit/UIKit ban applies only to PlayerCore).
import AIConnectorBridge
import AIConnectorMCP
import DesignSystem
import Foundation
import Observation
import Persistence
import Separation
import Services
import SwiftUI
import Visualizer

// `ThemePreset`, `AppearanceSetting`, `UpdateChannel` and `KaraokeCacheDirectoryChangeResult`
// live in `AppSettingsTypes.swift`, split off for this file's 400-line `file_length` ceiling.

// MARK: - AppSettings

/// The observable, `UserDefaults`-backed preference store for the macOS shell.
@MainActor
@Observable
public final class AppSettings {
    /// Preferred window appearance (Light / Dark / System).
    public var appearance: AppearanceSetting {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// Default ReplayGain normalization reference applied at launch.
    public var replayGainMode: ReplayGainMode {
        didSet { defaults.set(replayGainMode.rawValue, forKey: Keys.replayGainMode) }
    }

    /// Whether gapless continuation between queued tracks is enabled.
    public var gaplessEnabled: Bool {
        didSet { defaults.set(gaplessEnabled, forKey: Keys.gaplessEnabled) }
    }

    /// Name of the EQ preset applied at launch.
    public var defaultEQPresetName: String {
        didSet { defaults.set(defaultEQPresetName, forKey: Keys.defaultEQPresetName) }
    }

    /// Visualizer mode shown when the visualizer first opens.
    public var defaultVisualizerMode: VisualizerMode {
        didSet { defaults.set(defaultVisualizerMode.rawValue, forKey: Keys.defaultVisualizerMode) }
    }

    /// Sparkle update channel, read by `SparkleUpdaterDelegate.allowedChannels(for:)`.
    public var updateChannel: UpdateChannel {
        didSet { defaults.set(updateChannel.rawValue, forKey: Keys.updateChannel) }
    }

    /// Whether the inline spectrum visualizer is shown in the player bar.
    public var showVisualizer: Bool {
        didSet { defaults.set(showVisualizer, forKey: Keys.showVisualizer) }
    }

    /// The accent-color preset applied to the design tokens.
    public var themePreset: ThemePreset {
        didSet { defaults.set(themePreset.rawValue, forKey: Keys.themePreset) }
    }

    /// Whether newly imported tracks are auto-enriched (online metadata + lyrics).
    public var autoEnrichOnImport: Bool {
        didSet { defaults.set(autoEnrichOnImport, forKey: Keys.autoEnrichOnImport) }
    }

    /// Whether song/artist/album info is fetched from the internet (MusicBrainz/Wikipedia).
    public var onlineDataEnabled: Bool {
        didSet { defaults.set(onlineDataEnabled, forKey: Keys.onlineDataEnabled) }
    }

    /// Whether lyrics are fetched from the internet (LRCLIB).
    public var onlineLyricsEnabled: Bool {
        didSet { defaults.set(onlineLyricsEnabled, forKey: Keys.onlineLyricsEnabled) }
    }

    /// Whether the Netflix-style user-profiles feature is enabled. Off by default;
    /// when off the app behaves as the single built-in Guest profile.
    public var profilesEnabled: Bool {
        didSet { defaults.set(profilesEnabled, forKey: Keys.profilesEnabled) }
    }

    /// Whether karaoke (vocal-removal) mode is enabled. Off by default. When on,
    /// the pre-warm service separates upcoming tracks' instrumentals in the
    /// background so the player's mic button can swap to the vocals-removed mix.
    /// The stem-separation model ships only in Direct/Sparkle builds, so on App
    /// Store builds the feature resolves unavailable even while this is on.
    public var karaokeEnabled: Bool {
        didSet { defaults.set(karaokeEnabled, forKey: Keys.karaokeEnabled) }
    }

    /// The encode tier used when rendering a track's instrumental. Defaults to
    /// `.standard` (256 kbps AAC) so the capped cache holds more tracks; existing
    /// users' cached lossless files stay valid. A corrupt/missing stored raw value
    /// decodes back to `.standard`.
    public var karaokeQuality: InstrumentalRenderQuality {
        didSet { defaults.set(karaokeQuality.rawValue, forKey: Keys.karaokeQuality) }
    }

    /// Whether the instrumental cache is auto-pruned to stay under its byte cap.
    public var karaokePruneEnabled: Bool {
        didSet { defaults.set(karaokePruneEnabled, forKey: Keys.karaokePruneEnabled) }
    }

    /// The instrumental cache's on-disk byte cap (default 2 GiB).
    public var karaokeCacheCapBytes: Int64 {
        didSet { defaults.set(karaokeCacheCapBytes, forKey: Keys.karaokeCacheCapBytes) }
    }

    /// The user-chosen instrumental cache directory as a plain filesystem path, or
    /// `nil` to use `InstrumentalCacheLocation.defaultDirectory()`. A plain path,
    /// not a security-scoped bookmark (the macOS shell is non-sandboxed), mirroring
    /// `LibraryRootsStore`.
    public var karaokeCacheDirectoryPath: String? {
        didSet { defaults.set(karaokeCacheDirectoryPath, forKey: Keys.karaokeCacheDirectoryPath) }
    }

    /// The YouTube-download preferences, persisted as six flat scalars — see
    /// `AppSettings+Downloads.swift`.
    public var downloads: DownloadPreferences {
        didSet { persistDownloads() }
    }

    /// Sidebar-tree + folder-browser ordering — see `AppSettings+FolderSort.swift`.
    public var folderSort: FolderSortSettings {
        didSet { persistFolderSort() }
    }

    /// Which device playback is routed to and whether it is retuned to each track's
    /// own sample rate, persisted as two flat scalars — see `AppSettings+Output.swift`.
    public var output: OutputPreferences {
        didSet { persistOutput() }
    }

    // MARK: Intelligence (local AI)

    // The seven switches `AISettingsProviding` declares, all shipping ON because the
    // feature is on-device and lazy. Switching the top toggle off tears the AI graph
    // down but NEVER deletes what it materialised — those stay ordinary playlists.

    /// The master switch. `false` ⇒ no AI service is constructed at all.
    public var intelligenceEnabled: Bool {
        didSet { defaults.set(intelligenceEnabled, forKey: Keys.intelligenceEnabled) }
    }

    /// Natural-language playlist creation (`AIFeatureBundle.nlCreation`).
    public var nlCreationEnabled: Bool {
        didSet { defaults.set(nlCreationEnabled, forKey: Keys.nlCreationEnabled) }
    }

    /// Standing generated mixes (`AIFeatureBundle.autoMixes`).
    public var autoMixesEnabled: Bool {
        didSet { defaults.set(autoMixesEnabled, forKey: Keys.autoMixesEnabled) }
    }

    /// Library organisation proposals (`AIFeatureBundle.organization`).
    public var organizationEnabled: Bool {
        didSet { defaults.set(organizationEnabled, forKey: Keys.organizationEnabled) }
    }

    /// Rediscovery surfacing (`AIFeatureBundle.rediscovery`).
    public var rediscoveryEnabled: Bool {
        didSet { defaults.set(rediscoveryEnabled, forKey: Keys.rediscoveryEnabled) }
    }

    /// Listening insights and narrative (`AIFeatureBundle.insights`).
    public var insightsEnabled: Bool {
        didSet { defaults.set(insightsEnabled, forKey: Keys.insightsEnabled) }
    }

    /// Library hygiene analysers (`AIFeatureBundle.hygiene`).
    public var hygieneEnabled: Bool {
        didSet { defaults.set(hygieneEnabled, forKey: Keys.hygieneEnabled) }
    }

    // MARK: Intelligence (provider connectors)

    // The NON-SECRET half of connector configuration, witnessing
    // `AIConnectorSettingsProviding`. No API key, token or OAuth blob may join it —
    // secrets live in the Keychain, and `AIConnectorSettingsTests` enforces it.

    /// The connector the assistant routes through, or `nil` (the shipped default)
    /// for Apple Intelligence. Persisted verbatim; resolve it with
    /// `resolvedConnectorID(among:)` so an id no build registers degrades to `nil`.
    public var selectedConnectorID: String? {
        didSet { defaults.set(selectedConnectorID, forKey: Keys.connectorSelectedId) }
    }

    /// Each connector's chosen model, keyed by connector id. ONE dictionary, not a
    /// key per connector, so `@Observable` has a single stored property to
    /// instrument — todo 13's observation must see a model change.
    public var selectedConnectorModels: [String: String] {
        didSet { defaults.set(selectedConnectorModels, forKey: Keys.connectorSelectedModels) }
    }

    /// The Ollama server's base URL as typed, or `nil` for the connector default.
    public var ollamaHost: String? {
        didSet { defaults.set(ollamaHost, forKey: Keys.connectorOllamaHost) }
    }

    /// The connectors whose payload disclosure the listener has accepted.
    ///
    /// A per-id record rather than one global flag: accepting what Ollama-over-the-
    /// network receives says nothing about what Anthropic would. Empty by default,
    /// so a fresh install cannot reach any remote provider without an explicit
    /// acceptance — see ``IntelligenceConnectorConsentStoring``.
    public var consentedConnectorIDs: Set<String> {
        didSet { defaults.set(consentedConnectorIDs.sorted(), forKey: Keys.connectorConsentedIds) }
    }

    /// The connectors allowed to BROWSE the library during a conversation.
    ///
    /// A second, strictly narrower record beside ``consentedConnectorIDs`` rather than
    /// a widening of it. The first disclosure describes a bounded, one-shot payload
    /// (600 characters, 64 genre names, 50 artist names); a chat turn lets the
    /// provider ASK — repeatedly, on demand — for track titles, albums, years and
    /// listening statistics. That is a materially larger disclosure, so an existing
    /// acceptance cannot be read as covering it, and declining this one leaves the
    /// one-shot path exactly as it was.
    public var libraryBrowsingConsentedConnectorIDs: Set<String> {
        didSet {
            defaults.set(
                libraryBrowsingConsentedConnectorIDs.sorted(),
                forKey: Keys.connectorLibraryBrowsingConsentedIds
            )
        }
    }

    /// Whether MacAMP's OWN assistant may control playback. ON by default — alone
    /// among the AI grants here, because nothing leaves the machine, nothing is
    /// written, and every effect is audible at once and undone by pressing pause.
    /// Off means the control tools are never registered, so the model is not shown
    /// a capability it would be refused. In-app only; an external program asks
    /// through ``externalAccessControlEnabled``.
    public var assistantPlaybackControlEnabled: Bool {
        didSet { defaults.set(assistantPlaybackControlEnabled, forKey: Keys.assistantPlaybackControlEnabled) }
    }

    // MARK: Intelligence (external access — the in-process MCP server)

    /// Whether the loopback MCP server is serving. OFF by default — alone among the
    /// Intelligence switches, because it admits a DIFFERENT program rather than
    /// enabling something MacAMP does. Also requires ``externalAccessConsented``.
    public var externalAccessEnabled: Bool {
        didSet { defaults.set(externalAccessEnabled, forKey: Keys.externalAccessEnabled) }
    }

    /// Whether an external program may CONTROL playback. OFF by default, and a
    /// SEPARATE grant from ``externalAccessEnabled`` rather than a consequence of
    /// it: reading metadata is quiet, taking the transport is not, and MacAMP
    /// cannot tell which program is asking. The disclosure carries its own line for
    /// it; it is deliberately not a fourth consent RECORD.
    public var externalAccessControlEnabled: Bool {
        didSet { defaults.set(externalAccessControlEnabled, forKey: Keys.externalAccessControlEnabled) }
    }

    /// The loopback TCP port the MCP server binds. Never silently falls back to
    /// another number — the port on screen is the one a client has to be told.
    public var externalAccessPort: Int {
        didSet { defaults.set(externalAccessPort, forKey: Keys.externalAccessPort) }
    }

    /// Whether the external-access disclosure has been accepted. A THIRD record,
    /// never a widening of the two connector ones — rationale in
    /// `IntelligenceExternalAccessConsent.swift`.
    public var externalAccessConsented: Bool {
        didSet { defaults.set(externalAccessConsented, forKey: Keys.externalAccessConsented) }
    }

    // MARK: Intelligence (MCP client — external servers MacAMP may call)

    /// The external MCP servers the listener has configured, as JSON.
    ///
    /// The NON-SECRET half again: an endpoint records only the NAMES of the
    /// environment variables and headers that carry a credential, and the values
    /// live in the Keychain — see `MCPServerConfigStore`.
    public var mcpServers: [MCPServerDescriptor] {
        didSet { defaults.set(MCPServerConfigCoding.encode(mcpServers), forKey: Keys.mcpServers) }
    }

    /// The MCP servers whose trust disclosure the listener has accepted.
    ///
    /// A record of its own, not a field inside the blob above, for the reason
    /// `consentedConnectorIDs` is one: any code path that rewrites a server's
    /// configuration would otherwise be able to grant consent as a side effect.
    public var mcpConsentedServerIDs: Set<String> {
        didSet { defaults.set(mcpConsentedServerIDs.sorted(), forKey: Keys.mcpConsentedServerIds) }
    }

    // MARK: Intelligence (web suggestions — the optional public-web lookups)

    /// Whether the assistant may consult the public web when it suggests music.
    /// OFF by default, and inert without ``webSuggestionsConsented``.
    public var webSuggestionsEnabled: Bool {
        didSet { defaults.set(webSuggestionsEnabled, forKey: Keys.webSuggestionsEnabled) }
    }

    /// Whether the web-suggestions disclosure has been accepted. A record of its
    /// own, NEVER derived from ``webSuggestionsEnabled``: a switch flipped is not a
    /// disclosure read, and only a separate record tells "declined" from "never
    /// asked" after a restore.
    public var webSuggestionsConsented: Bool {
        didSet { defaults.set(webSuggestionsConsented, forKey: Keys.webSuggestionsConsented) }
    }

    // Karaoke wiring seams set by `AppEnvironment` (Task 17) so the Playback pane
    // drives the karaoke services without importing them. Nil until wired ⇒ the
    // pane degrades: toggling only persists, the readout shows zero, Clear no-ops.

    /// Routes the karaoke on/off toggle to the pre-warm service's `setEnabled(_:)`.
    @ObservationIgnored public var onKaraokeEnabledChanged: ((Bool) -> Void)?
    /// Reports the instrumental cache's current on-disk size, in bytes.
    @ObservationIgnored public var karaokeCacheByteSize: (() async -> Int64)?
    /// Clears the instrumental cache (a no-op when it is already empty).
    @ObservationIgnored public var clearKaraokeCache: (() async throws -> Void)?
    /// Routes a render-quality change to the separation pipeline's quality provider
    /// (future renders use the new tier; already-cached files are unaffected).
    @ObservationIgnored public var onKaraokeQualityChanged: ((InstrumentalRenderQuality) -> Void)?
    /// Reports a change to the prune toggle and/or the cache byte cap so the cache
    /// applies the new limits.
    @ObservationIgnored public var onKaraokeCacheLimitsChanged: ((Bool, Int64) -> Void)?
    /// Relocates the instrumental cache to a new directory (`nil` ⇒ the default),
    /// returning the outcome for the pane to surface.
    @ObservationIgnored public var changeKaraokeCacheDirectory: ((URL?) async -> KaraokeCacheDirectoryChangeResult)?
    /// Reports whether the stem-separation model is available (drives the pane's notice).
    @ObservationIgnored public var karaokeSeparatorAvailable: (() async -> Bool)?

    @ObservationIgnored let defaults: UserDefaults

    /// Creates a settings store backed by `defaults` (`.standard` in the app).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearanceSetting(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .dark
        replayGainMode = ReplayGainMode(rawValue: defaults.string(forKey: Keys.replayGainMode) ?? "") ?? .off
        gaplessEnabled = defaults.object(forKey: Keys.gaplessEnabled) as? Bool ?? true
        defaultEQPresetName = defaults.string(forKey: Keys.defaultEQPresetName) ?? EQPreset.flat.name
        defaultVisualizerMode = VisualizerMode(rawValue: defaults.string(forKey: Keys.defaultVisualizerMode) ?? "")
            ?? .bars
        updateChannel = UpdateChannel(rawValue: defaults.string(forKey: Keys.updateChannel) ?? "") ?? .stable
        showVisualizer = defaults.object(forKey: Keys.showVisualizer) as? Bool ?? true
        themePreset = ThemePreset.migratingStoredValue(in: defaults, forKey: Keys.themePreset)
        autoEnrichOnImport = defaults.object(forKey: Keys.autoEnrichOnImport) as? Bool ?? true
        onlineDataEnabled = defaults.object(forKey: Keys.onlineDataEnabled) as? Bool ?? true
        onlineLyricsEnabled = defaults.object(forKey: Keys.onlineLyricsEnabled) as? Bool ?? true
        profilesEnabled = defaults.object(forKey: Keys.profilesEnabled) as? Bool ?? false
        karaokeEnabled = defaults.object(forKey: Keys.karaokeEnabled) as? Bool ?? false
        karaokeQuality = InstrumentalRenderQuality(rawValue: defaults.string(forKey: Keys.karaokeQuality) ?? "")
            ?? .standard
        karaokePruneEnabled = defaults.object(forKey: Keys.karaokePruneEnabled) as? Bool ?? true
        karaokeCacheCapBytes = defaults.object(forKey: Keys.karaokeCacheCapBytes) as? Int64 ?? 2 * 1024 * 1024 * 1024
        karaokeCacheDirectoryPath = defaults.string(forKey: Keys.karaokeCacheDirectoryPath)
        downloads = AppSettings.loadDownloads(from: defaults)
        folderSort = AppSettings.loadFolderSort(from: defaults)
        output = AppSettings.loadOutput(from: defaults)
        intelligenceEnabled = defaults.object(forKey: Keys.intelligenceEnabled) as? Bool ?? true
        nlCreationEnabled = defaults.object(forKey: Keys.nlCreationEnabled) as? Bool ?? true
        autoMixesEnabled = defaults.object(forKey: Keys.autoMixesEnabled) as? Bool ?? true
        organizationEnabled = defaults.object(forKey: Keys.organizationEnabled) as? Bool ?? true
        rediscoveryEnabled = defaults.object(forKey: Keys.rediscoveryEnabled) as? Bool ?? true
        insightsEnabled = defaults.object(forKey: Keys.insightsEnabled) as? Bool ?? true
        hygieneEnabled = defaults.object(forKey: Keys.hygieneEnabled) as? Bool ?? true
        selectedConnectorID = defaults.string(forKey: Keys.connectorSelectedId)
        selectedConnectorModels = AppSettings.storedModelSelections(in: defaults)
        ollamaHost = defaults.string(forKey: Keys.connectorOllamaHost)
        consentedConnectorIDs = AppSettings.storedIDSet(in: defaults, forKey: Keys.connectorConsentedIds)
        libraryBrowsingConsentedConnectorIDs = AppSettings
            .storedIDSet(in: defaults, forKey: Keys.connectorLibraryBrowsingConsentedIds)
        let mcpConsented = AppSettings.storedIDSet(in: defaults, forKey: Keys.mcpConsentedServerIds)
        mcpConsentedServerIDs = mcpConsented
        mcpServers = MCPServerConfigCoding.decode(defaults.data(forKey: Keys.mcpServers), consentedIDs: mcpConsented)
        assistantPlaybackControlEnabled = defaults
            .object(forKey: Keys.assistantPlaybackControlEnabled) as? Bool ?? true
        externalAccessEnabled = defaults.object(forKey: Keys.externalAccessEnabled) as? Bool ?? false
        externalAccessControlEnabled = defaults
            .object(forKey: Keys.externalAccessControlEnabled) as? Bool ?? false
        externalAccessConsented = defaults.object(forKey: Keys.externalAccessConsented) as? Bool ?? false
        webSuggestionsEnabled = defaults.object(forKey: Keys.webSuggestionsEnabled) as? Bool ?? false
        webSuggestionsConsented = defaults.object(forKey: Keys.webSuggestionsConsented) as? Bool ?? false
        externalAccessPort = AppSettings.storedExternalAccessPort(in: defaults)
    }

    /// Namespaced `UserDefaults` keys — see `AppSettingsKeys.swift`.
    private typealias Keys = AppSettingsKeys
}
