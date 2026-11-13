// LibraryPane — the Library (music folders) preferences pane.
//
// Reuses Task 29's `LibraryAccessController` (over `LibraryRootsStore`): it lists
// the chosen roots with their last-probed access status, opens the folder picker
// to add roots, removes roots, re-probes access, and surfaces a recovery banner
// when a root is unreadable (TCC denial). The controller is owned by
// `PreferencesView` as `@State` and injected here so construction (which probes
// every root) happens once. Copy resolves through `FileAccessStrings`; folder
// paths are non-translatable and rendered with `Text(verbatim:)`.
import DesignSystem
import SwiftUI

/// The music-folders pane: add/remove library roots and recover from denials.
struct LibraryPreferencesPane: View {
    let controller: LibraryAccessController

    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var settings = settings
        PreferencePane(
            icon: "folder",
            title: PreferencesStrings.tabLibrary,
            subtitle: PreferencesStrings.librarySubtitle
        ) {
            Section {
                header
            }
            if controller.hasDeniedAccess {
                Section { deniedBanner }
            }
            rootsSection
            Section {
                actions
            }
            EnrichmentSettingsSection(autoEnrich: $settings.autoEnrichOnImport)
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: tokens.spacing.small) {
            VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                Text(FileAccessStrings.title)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                Text(FileAccessStrings.description)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: tokens.spacing.small)
            addFolderButton
        }
    }

    private var addFolderButton: some View {
        Button {
            Task { await controller.requestAccess() }
        } label: {
            Label { Text(FileAccessStrings.addFolder) } icon: { Image(systemName: "plus") }
        }
    }

    @ViewBuilder
    private var rootsSection: some View {
        if controller.roots.isEmpty {
            Section { emptyState }
        } else {
            Section {
                ForEach(controller.roots) { root in
                    LibraryRootRow(root: root) { controller.removeRoot(root) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            Text(FileAccessStrings.emptyTitle)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Text(FileAccessStrings.emptyMessage)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, tokens.spacing.small)
    }

    private var deniedBanner: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            Label {
                Text(FileAccessStrings.deniedTitle)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(tokens.colors.warning.resolve(scheme))
            }
            .font(tokens.typography.headline.font)
            Text(FileAccessStrings.deniedMessage)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                controller.openSystemSettings()
            } label: {
                Text(FileAccessStrings.openSettings)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: tokens.spacing.small) {
            addFolderButton
            Spacer()
            Button {
                environment.libraryFolders.refreshLibrary()
            } label: {
                Label { Text(FileAccessStrings.refresh) } icon: { Image(systemName: "arrow.clockwise") }
            }
            .disabled(controller.roots.isEmpty)
        }
    }
}

// MARK: - LibraryRootRow

/// One library root: folder name, full path, access status and a remove button.
struct LibraryRootRow: View {
    let root: LibraryRoot
    let onRemove: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: tokens.spacing.small) {
            Image(systemName: "folder.fill")
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
            VStack(alignment: .leading, spacing: tokens.spacing.hairline) {
                Text(verbatim: root.url.lastPathComponent)
                    .font(tokens.typography.body.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                Text(verbatim: root.url.path)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: tokens.spacing.small)
            statusBadge
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(FileAccessStrings.removeFolder))
            .help(Text(FileAccessStrings.removeFolder))
        }
        .padding(.vertical, tokens.spacing.xxSmall)
    }

    private var statusBadge: some View {
        Label {
            Text(statusLabel)
        } icon: {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
        }
        .labelStyle(.iconOnly)
        .font(tokens.typography.callout.font)
        .accessibilityLabel(Text(statusLabel))
        .help(Text(statusLabel))
    }

    private var statusLabel: LocalizedStringResource {
        switch root.status {
        case .accessible: FileAccessStrings.statusAccessible
        case .denied: FileAccessStrings.statusDenied
        case .missing: FileAccessStrings.statusMissing
        }
    }

    private var statusSymbol: String {
        switch root.status {
        case .accessible: "checkmark.circle.fill"
        case .denied: "exclamationmark.triangle.fill"
        case .missing: "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch root.status {
        case .accessible: tokens.colors.success.resolve(scheme)
        case .denied: tokens.colors.warning.resolve(scheme)
        case .missing: tokens.colors.danger.resolve(scheme)
        }
    }
}

#Preview("Library — with roots") {
    LibraryPreferencesPane(
        controller: LibraryAccessController(
            store: FakeLibraryRootsStore(roots: [
                URL(fileURLWithPath: "/Users/dj/Music"),
                URL(fileURLWithPath: "/Volumes/Archive/FLAC"),
            ]),
            picker: FakeFolderPicker(),
            probe: FakeFileAccessProbe(
                default: .accessible,
                statuses: ["/Volumes/Archive/FLAC": .missing]
            ),
            settings: FakeSystemSettingsOpener()
        )
    )
    .environment(AppEnvironment.preview())
    .environment(AppSettings.preview)
    .designTokens(.standard)
}

#Preview("Library — empty") {
    LibraryPreferencesPane(
        controller: LibraryAccessController(
            store: FakeLibraryRootsStore(),
            picker: FakeFolderPicker(),
            probe: FakeFileAccessProbe(),
            settings: FakeSystemSettingsOpener()
        )
    )
    .environment(AppEnvironment.preview())
    .environment(AppSettings.preview)
    .designTokens(.standard)
}
