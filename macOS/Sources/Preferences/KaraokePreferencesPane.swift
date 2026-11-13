// KaraokePreferencesPane — the Karaoke tab in the macOS Settings window.
//
// Karaoke (vocal-removal) mode has its own pane: an enable toggle, the
// instrumental encode-quality picker, the on-disk cache location, an optional
// size cap with auto-prune, and the cache size/clear controls. Every control
// binds straight to the shared `AppSettings` karaoke seams, which are nil until
// `AppEnvironment` wires them — so the pane degrades gracefully in previews and
// before composition: toggles only persist, the readout shows zero, and the
// buttons are inert no-ops. Copy resolves through `PreferencesStrings`; the
// separation model itself lives in `Separation`.
import AppKit
import DesignSystem
import Foundation
import Models
import Separation
import SwiftUI

/// The Karaoke settings pane: enable, quality, cache location, size cap, usage.
struct KaraokePreferencesPane: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        PreferencePane(
            icon: "music.mic",
            title: PreferencesStrings.tabKaraoke,
            subtitle: PreferencesStrings.karaokeSubtitle
        ) {
            KaraokeEnableSection(settings: settings)
            KaraokeQualitySection(settings: settings)
            KaraokeCacheDirectorySection(settings: settings)
            KaraokePruneSection(settings: settings)
            KaraokeCacheUsageSection(settings: settings)
        }
    }
}

// MARK: - Enable

/// The enable toggle, its explanatory caption, and an unavailable notice shown
/// when karaoke is on but the separation model cannot run in this build.
private struct KaraokeEnableSection: View {
    @Bindable var settings: AppSettings
    @State private var separatorAvailable = true

    var body: some View {
        Section {
            Toggle(isOn: $settings.karaokeEnabled) {
                Text(PreferencesStrings.karaoke)
            }
            .accessibilityIdentifier("preferences.karaoke.toggle")
            PreferenceCaption(text: PreferencesStrings.karaokeCaption)
            if settings.karaokeEnabled, !separatorAvailable {
                KaraokeNoticeLabel(kind: .warning, text: Text(PreferencesStrings.karaokeUnavailable))
            }
        }
        .task { separatorAvailable = await settings.karaokeSeparatorAvailable?() ?? true }
        .onChange(of: settings.karaokeEnabled) { _, enabled in
            settings.onKaraokeEnabledChanged?(enabled)
        }
    }
}

// MARK: - Quality

/// The instrumental encode-quality picker; the caption states the choice applies
/// only to newly created karaoke versions.
private struct KaraokeQualitySection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            Picker(selection: $settings.karaokeQuality) {
                Text(PreferencesStrings.karaokeQualityStandard).tag(InstrumentalRenderQuality.standard)
                Text(PreferencesStrings.karaokeQualityLossless).tag(InstrumentalRenderQuality.lossless)
            } label: {
                Text(PreferencesStrings.karaokeQuality)
            }
            PreferenceCaption(text: PreferencesStrings.karaokeQualityCaption)
        }
        .onChange(of: settings.karaokeQuality) { _, quality in
            settings.onKaraokeQualityChanged?(quality)
        }
    }
}

// MARK: - Cache directory

/// The cache location readout with "Choose…" (a folder picker) and "Reset to
/// Default", surfacing the change result inline.
private struct KaraokeCacheDirectorySection: View {
    @Bindable var settings: AppSettings
    @State private var feedback: DirectoryFeedback?

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: displayPath)
            } label: {
                Text(PreferencesStrings.karaokeCacheDirectory)
            }
            HStack {
                Button(action: chooseDirectory) {
                    Text(PreferencesStrings.karaokeChooseDirectory)
                }
                Button { changeDirectory(to: nil) } label: {
                    Text(PreferencesStrings.karaokeResetDirectory)
                }
            }
            if let feedback {
                feedbackRow(feedback)
            }
        }
    }

    private var displayPath: String {
        settings.karaokeCacheDirectoryPath
            ?? InstrumentalCacheLocation.defaultDirectory()?.path
            ?? ""
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        changeDirectory(to: url)
    }

    private func changeDirectory(to url: URL?) {
        Task {
            let result = await settings.changeKaraokeCacheDirectory?(url)
            apply(result)
        }
    }

    private func apply(_ result: KaraokeCacheDirectoryChangeResult?) {
        switch result {
        case .moved, .none:
            feedback = nil
        case .freshStart:
            feedback = .freshStart
        case .failed:
            feedback = .failed
        case let .rejected(reason):
            feedback = .rejected(reason)
        }
    }

    @ViewBuilder
    private func feedbackRow(_ feedback: DirectoryFeedback) -> some View {
        switch feedback {
        case .freshStart:
            KaraokeNoticeLabel(kind: .info, text: Text(PreferencesStrings.karaokeCacheFreshStart))
        case .failed:
            KaraokeNoticeLabel(kind: .warning, text: Text(PreferencesStrings.karaokeCacheChangeFailed))
        case let .rejected(reason):
            KaraokeNoticeLabel(kind: .warning, text: Text(verbatim: reason))
        }
    }
}

/// The outcome the cache-directory section surfaces to the user after a change.
private enum DirectoryFeedback {
    case freshStart
    case failed
    case rejected(String)
}

// MARK: - Size cap

/// The cache size cap: an auto-prune toggle and, only when pruning is on, the
/// maximum-size picker.
private struct KaraokePruneSection: View {
    @Bindable var settings: AppSettings

    private static let capOptions: [Int64] = [1 << 30, 2 << 30, 5 << 30, 10 << 30]

    var body: some View {
        Section {
            Toggle(isOn: $settings.karaokePruneEnabled) {
                Text(PreferencesStrings.karaokePrune)
            }
            PreferenceCaption(text: PreferencesStrings.karaokePruneCaption)
            if settings.karaokePruneEnabled {
                Picker(selection: $settings.karaokeCacheCapBytes) {
                    ForEach(Self.capOptions, id: \.self) { bytes in
                        Text(verbatim: bytes.formatted(.byteCount(style: .binary))).tag(bytes)
                    }
                } label: {
                    Text(PreferencesStrings.karaokeCacheCap)
                }
            }
        }
        .onChange(of: settings.karaokePruneEnabled) { _, enabled in
            settings.onKaraokeCacheLimitsChanged?(enabled, settings.karaokeCacheCapBytes)
        }
        .onChange(of: settings.karaokeCacheCapBytes) { _, cap in
            settings.onKaraokeCacheLimitsChanged?(settings.karaokePruneEnabled, cap)
        }
    }
}

// MARK: - Usage

/// The cached-instrumentals size readout and the destructive clear button.
private struct KaraokeCacheUsageSection: View {
    @Bindable var settings: AppSettings
    @State private var cacheBytes: Int64 = 0
    @State private var isClearing = false

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: cacheBytes.formatted(.byteCount(style: .file)))
            } label: {
                Text(PreferencesStrings.karaokeCacheSize)
            }
            Button(role: .destructive, action: clearCache) {
                Text(PreferencesStrings.karaokeClearCache)
            }
            .disabled(isClearing)
        }
        .task { await refreshCacheSize() }
    }

    private func refreshCacheSize() async {
        cacheBytes = await settings.karaokeCacheByteSize?() ?? 0
    }

    private func clearCache() {
        isClearing = true
        Task {
            try? await settings.clearKaraokeCache?()
            await refreshCacheSize()
            isClearing = false
        }
    }
}

// MARK: - Notice row

/// A caption-styled notice row with an info or warning icon, used for the
/// unavailable notice and the cache-directory change feedback.
private struct KaraokeNoticeLabel: View {
    enum Kind {
        case info
        case warning
    }

    let kind: Kind
    let text: Text

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Label {
            text
                .font(tokens.typography.caption.font)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch kind {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .info: tokens.colors.textSecondary.resolve(scheme)
        case .warning: tokens.colors.warning.resolve(scheme)
        }
    }
}

#Preview {
    KaraokePreferencesPane()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .designTokens(.standard)
}
