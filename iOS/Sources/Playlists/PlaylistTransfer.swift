// PlaylistTransfer — iOS playlist import / export (Task 21).
//
// Export renders the playlist to a temporary file off the main actor (in
// ``PlaylistImportExportViewModel``) and shares it via `ShareLink`. Import reads a
// picked file off the main actor and creates a new playlist, surfacing entries
// that matched no library track in a sheet (never silently dropped).
import Persistence
import SwiftUI
import UniformTypeIdentifiers

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

enum PlaylistTransferTypes {
    static let importTypes: [UTType] = {
        let byExtension = ["m3u", "m3u8", "pls", "jspf"].compactMap { UTType(filenameExtension: $0) }
        return byExtension + [.json, .plainText]
    }()
}

/// A playlist chosen for export (the row long-press target).
struct PlaylistExportRequest: Identifiable {
    let id: Int64
    let name: String
}

// MARK: - Export sheet

/// Picks a format + path style, renders a temporary file, and shares it.
struct PlaylistExportSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let request: PlaylistExportRequest

    @State private var format: PlaylistFormat = .json
    @State private var relativePaths = false
    @State private var exportedURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Picker(selection: $format) {
                    ForEach(PlaylistFormat.allCases, id: \.self) { option in
                        Text(verbatim: option.displayName).tag(option)
                    }
                } label: {
                    Text(MacAMPStrings.playlistExportFormat)
                }
                Toggle(isOn: $relativePaths) {
                    Text(MacAMPStrings.playlistExportRelative)
                }
                Section {
                    shareRow
                }
            }
            .navigationTitle(Text(MacAMPStrings.playlistExportTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(MacAMPStrings.playlistsCancel) }
                }
            }
            .task(id: "\(format.rawValue)-\(relativePaths)") { await prepare() }
        }
    }

    @ViewBuilder
    private var shareRow: some View {
        if let url = exportedURL {
            ShareLink(item: url) {
                Label {
                    Text(MacAMPStrings.playlistShareAction)
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text(MacAMPStrings.playlistPreparing)
            }
        }
    }

    private func prepare() async {
        exportedURL = nil
        exportedURL = try? await environment.playlistImportExport.exportToTemporaryFile(
            playlistId: request.id,
            playlistName: request.name,
            format: format,
            relativePaths: relativePaths
        )
    }
}

// MARK: - Unresolved sheet

/// Lists imported entries that matched no library track.
struct PlaylistUnresolvedSheet: View {
    @Environment(\.dismiss) private var dismiss

    let entries: [UnresolvedPlaylistEntry]
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(entries, id: \.lineNumber) { entry in
                        Text(verbatim: entry.rawPath)
                            .lineLimit(2)
                    }
                } header: {
                    Text(MacAMPStrings.playlistUnresolvedMessage)
                }
            }
            .navigationTitle(Text(MacAMPStrings.playlistUnresolvedTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { onDone(); dismiss() } label: { Text(MacAMPStrings.done) }
                }
            }
        }
    }
}

// MARK: - Import actions modifier

/// Adds the Import toolbar button, the file picker, and the import-result sheets
/// to a host view, all with self-contained state (a single `.modifier` at the
/// call site keeps the host's own code untouched).
struct PlaylistImportActions: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @State private var showImporter = false
    @State private var showUnresolved = false
    @State private var importFailed = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showImporter = true } label: {
                        Label {
                            Text(MacAMPStrings.playlistImport)
                        } icon: {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: PlaylistTransferTypes.importTypes,
                allowsMultipleSelection: false,
                onCompletion: handleImport
            )
            .sheet(isPresented: $showUnresolved) {
                PlaylistUnresolvedSheet(entries: environment.playlistImportExport.unresolved) {
                    environment.playlistImportExport.clearUnresolved()
                }
            }
            .alert(Text(MacAMPStrings.playlistImportFailedTitle), isPresented: $importFailed) {
                Button {} label: { Text(MacAMPStrings.done) }
            } message: {
                Text(MacAMPStrings.playlistImportFailed)
            }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        Task {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try await environment.playlistImportExport.importPlaylist(
                    from: url,
                    profileId: environment.profileService.activeProfile.id ?? ProfileRecord.guestID
                )
                try? await environment.playlists.loadInitialPlaylists()
                showUnresolved = !environment.playlistImportExport.unresolved.isEmpty
            } catch {
                importFailed = true
            }
        }
    }
}
