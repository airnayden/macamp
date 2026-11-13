// PreferencesView — the macOS Settings window.
//
// Native sidebar navigation keeps every Settings section reachable at the window's
// minimum width. Each detail pane retains its shared token-styled header and Form.
// Preferences remain in AppSettings / UserDefaults, never the library database.
import DesignSystem
import SwiftUI

/// The macOS Settings window, with independently scrolling navigation and detail.
struct PreferencesView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var selection: PreferencesSection? = .general

    private var selectedSection: PreferencesSection {
        selection ?? .general
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(PreferencesSection.allCases, selection: $selection) { section in
                HStack {
                    Label {
                        Text(section.title)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: section.systemImage)
                    }
                    Spacer(minLength: 0)
                }
                .font(tokens.typography.callout.font)
                .contentShape(Rectangle())
                .tag(section)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(section.title))
                .accessibilityIdentifier("preferences.section.\(section.rawValue)")
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .accessibilityIdentifier("preferences.sidebar")
            .navigationSplitViewColumnWidth(
                min: PreferenceMetrics.sidebarMinWidth,
                ideal: PreferenceMetrics.sidebarIdealWidth,
                max: PreferenceMetrics.sidebarMaxWidth
            )
        } detail: {
            VStack(spacing: 0) { selectedPane }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("preferences.detail")
                .navigationTitle(Text(selectedSection.title))
        }
        .navigationSplitViewStyle(.balanced)
        .tint(tokens.colors.accent.resolve(scheme))
        .frame(minWidth: PreferenceMetrics.windowMinWidth, minHeight: PreferenceMetrics.windowMinHeight)
        .accessibilityIdentifier("preferences.window")
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch selectedSection {
        case .general: GeneralPreferencesPane()
        case .library: LibraryPreferencesPane(controller: environment.libraryAccess)
        case .downloads: DownloadsPreferencesPane()
        case .playback: PlaybackPreferencesPane()
        case .output: OutputPreferencesPane()
        case .equalizer: EQPreferencesPane()
        case .visualizer: VisualizerPreferencesPane()
        case .karaoke: KaraokePreferencesPane()
        case .intelligence: IntelligencePreferencesPane()
        case .online: OnlinePreferencesPane()
        case .profiles: ProfilesPreferencesPane()
        case .updates: UpdatesPreferencesPane()
        case .acknowledgments: AcknowledgmentsPreferencesPane()
        }
    }
}

/// Container dimensions shared by Settings and its panes. Sidebar labels may
/// wrap and scroll; adding a section never increases the window's width floor.
enum PreferenceMetrics {
    static let windowMinWidth: CGFloat = 800
    static let windowMinHeight: CGFloat = 520
    static let paneMinHeight: CGFloat = 380
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 200
    static let sidebarMaxWidth: CGFloat = 260
}

// MARK: - Shared pane chrome

/// A consistently-sized preferences pane: a token-styled ``PreferencePaneHeader``
/// hero over a grouped `Form` sitting on the design-system canvas, so every section
/// adopts the same width, header treatment and surface layering.
struct PreferencePane<Content: View>: View {
    private let icon: String
    private let title: LocalizedStringResource
    private let subtitle: LocalizedStringResource
    private let content: Content

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    init(
        icon: String,
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreferencePaneHeader(icon: icon, title: title, subtitle: subtitle)
                .padding(.horizontal, tokens.spacing.large)
                .padding(.top, tokens.spacing.large)
                .padding(.bottom, tokens.spacing.small)
            Rectangle()
                .fill(tokens.colors.separator.resolve(scheme))
                .frame(height: tokens.spacing.hairline)
            Form { content }
                .formStyle(.grouped)
                .tint(tokens.colors.accent.resolve(scheme))
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("preferences.form")
        }
        .background(tokens.colors.canvas.resolve(scheme))
        // Fill the detail column without imposing an ideal size on section changes.
        .frame(
            maxWidth: .infinity,
            minHeight: PreferenceMetrics.paneMinHeight,
            maxHeight: .infinity
        )
    }
}

/// The hero atop every pane: an accent SF Symbol in a soft accent chip beside a
/// title and a one-line subtitle. Mirrors the Library pane's own header so all
/// sections read as one family. Sizes from font + spacing tokens, so it scales
/// with Dynamic Type rather than fixed point sizes.
struct PreferencePaneHeader: View {
    let icon: String
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: tokens.spacing.small) {
            Image(systemName: icon)
                .font(tokens.typography.titleMedium.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .padding(tokens.spacing.xSmall)
                .background(
                    RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
                        .fill(tokens.colors.accentMuted.resolve(scheme))
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: tokens.spacing.hairline) {
                Text(title)
                    .font(tokens.typography.titleMedium.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                Text(subtitle)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A secondary, token-styled caption shown beneath a control to explain it.
struct PreferenceCaption: View {
    let text: LocalizedStringResource

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Row styling

private struct PreferenceRowSurface: ViewModifier {
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.listRowBackground(tokens.colors.surface.resolve(scheme))
    }
}

extension View {
    /// Fills a `Form` section's rows with the design-system surface token, layering
    /// the section card over the pane canvas once the default scroll background is
    /// hidden.
    func preferenceRowSurface() -> some View {
        modifier(PreferenceRowSurface())
    }
}

#Preview {
    PreferencesView()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .environment(UpdaterModel.preview)
        .designTokens(.standard)
}
