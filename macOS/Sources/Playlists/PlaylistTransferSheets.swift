// PlaylistTransferSheets — the export-options sheet and the post-import
// "unresolved entries" summary for the macOS playlists pane.
import DesignSystem
import os
import Persistence
import SwiftUI
import ViewModels

extension PlaylistFormat {
    /// Non-translatable format token shown in the export picker.
    var displayName: String {
        switch self {
        case .m3u: "M3U"
        case .m3u8: "M3U8"
        case .pls: "PLS"
        case .json: "JSPF (JSON)"
        }
    }
}

/// Picks a file format + path style, then a save destination. The render + write
/// happen off the main actor inside ``PlaylistImportExportViewModel``.
struct PlaylistExportSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let playlistId: Int64
    let playlistName: String

    @State private var format: PlaylistFormat = .json
    @State private var relativePaths = false
    @State private var isExporting = false
    @State private var exportFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.large) {
            Text(MacAMPStrings.playlistExportTitle)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Picker(selection: $format) {
                ForEach(PlaylistFormat.allCases, id: \.self) { option in
                    Text(verbatim: option.displayName).tag(option)
                }
            } label: {
                Text(MacAMPStrings.playlistExportFormat)
            }
            Toggle(isOn: $relativePaths) {
                Text(MacAMPStrings.playlistExportRelativePaths)
            }
            actions
        }
        .padding(tokens.spacing.large)
        .frame(width: 360)
        .alert(Text(MacAMPStrings.playlistExportFailedTitle), isPresented: $exportFailed) {
            Button(role: .cancel) {} label: { Text(MacAMPStrings.playlistImportDone) }
        } message: {
            Text(MacAMPStrings.playlistExportFailedMessage)
        }
    }

    private var actions: some View {
        HStack(spacing: tokens.spacing.small) {
            if isExporting {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button(role: .cancel) { dismiss() } label: {
                Text(MacAMPStrings.playlistCancel)
            }
            .pointingHandCursor()
            Button(action: export) {
                Text(MacAMPStrings.playlistExportAction)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isExporting)
            .pointingHandCursor()
        }
    }

    private func export() {
        guard let url = PlaylistFilePanels.chooseExportDestination(
            suggestedName: playlistName,
            format: format
        ) else { return }
        isExporting = true
        Task { await write(to: url) }
    }

    /// Dismisses on success ONLY. `.alert` is attached to this sheet, so dismissing
    /// first — what the previous unconditional `dismiss()` did, paired with a
    /// swallowing `try?` — tore the alert down before it could ever render and made
    /// every failure look exactly like a success.
    private func write(to url: URL) async {
        defer { isExporting = false }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            try await environment.playlistImportExport.exportPlaylist(
                playlistId: playlistId,
                to: url,
                format: format,
                relativePaths: relativePaths
            )
        } catch {
            // A denied scope request (`didAccess == false`) is not itself fatal — a
            // save-panel URL is already writable in an unsandboxed build, and under
            // App Store sandboxing powerbox grants the extension before we ask — so
            // it is reported only when the write it would have authorised failed.
            Self.log.error(
                "playlist export failed (securityScope=\(didAccess, privacy: .public)): \(error, privacy: .public)"
            )
            exportFailed = true
            return
        }
        environment.toast.show(
            text: String(localized: MacAMPStrings.playlistExportSucceeded),
            icon: "square.and.arrow.up"
        )
        dismiss()
    }

    private static let log = Logger(subsystem: "si.macamp.MacAMP", category: "playlist-export")
}

/// Lists imported entries that matched no library track, so an import never
/// silently drops anything.
struct PlaylistUnresolvedSheet: View {
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let entries: [UnresolvedPlaylistEntry]
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.medium) {
            Text(MacAMPStrings.playlistUnresolvedTitle)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Text(MacAMPStrings.playlistUnresolvedMessage)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            List(entries, id: \.lineNumber) { entry in
                HStack(spacing: tokens.spacing.small) {
                    Text(verbatim: "\(entry.lineNumber)")
                        .font(tokens.typography.timecode.font)
                        .monospacedDigit()
                        .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    Text(verbatim: entry.rawPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                }
            }
            .frame(minHeight: 180)
            HStack {
                Spacer()
                Button { onDone(); dismiss() } label: {
                    Text(MacAMPStrings.playlistImportDone)
                }
                .keyboardShortcut(.defaultAction)
                .pointingHandCursor()
            }
        }
        .padding(tokens.spacing.large)
        .frame(width: 440)
    }
}
