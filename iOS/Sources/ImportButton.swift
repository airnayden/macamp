// ImportButton — the library toolbar affordance that imports audio into MacAMP.
//
// Presents the system document picker (audio files *and* folders, multi-select),
// then hands the security-scoped URLs to a ``DocumentImporter`` built from the
// shared ``AppEnvironment`` (the scanner + the GRDB-backed bookmark store). While
// a scan runs the button swaps its label for a progress indicator bound to the
// scanner's reported fraction. The importer is created lazily in `.task` because
// the environment is only available inside `body`; the call site stays zero-arg
// (`ImportButton()`), so `LibraryScreen` needs no change.
import Persistence
import Services
import SwiftUI
import UniformTypeIdentifiers

/// A toolbar button that imports music into the library.
struct ImportButton: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var importer: DocumentImporter?
    @State private var isPresentingPicker = false

    var body: some View {
        Button {
            isPresentingPicker = true
        } label: {
            label
        }
        .disabled(importer?.isImporting == true)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityHint(Text(MacAMPStrings.a11yHintImport))
        .fileImporter(
            isPresented: $isPresentingPicker,
            allowedContentTypes: [.audio, .folder],
            allowsMultipleSelection: true,
            onCompletion: handlePick
        )
        .task { activateImporter() }
    }
}

// MARK: - Label

private extension ImportButton {
    @ViewBuilder
    var label: some View {
        if let importer, importer.isImporting {
            importingLabel(importer.progress)
        } else {
            Label { Text(MacAMPStrings.importMusic) } icon: { Image(systemName: "plus") }
        }
    }

    @ViewBuilder
    func importingLabel(_ progress: ImportProgress?) -> some View {
        if let progress, progress.total > 0 {
            ProgressView(value: progress.fraction, total: 1)
                .frame(width: 88)
                .accessibilityValue(Text(percentText(progress.fraction)))
        } else {
            ProgressView()
        }
    }

    var accessibilityTitle: LocalizedStringResource {
        importer?.isImporting == true ? Strings.inProgress : MacAMPStrings.importMusic
    }

    func percentText(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

// MARK: - Actions

private extension ImportButton {
    func activateImporter() {
        guard importer == nil else { return }
        importer = DocumentImporter(
            scanner: environment.scanner,
            bookmarks: SecurityScopedBookmarkManager(
                store: GRDBBookmarkStore(database: environment.database)
            ),
            accessOwner: environment.libraryAccess
        )
    }

    func handlePick(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, !urls.isEmpty else { return }
        activateImporter()
        guard let importer else { return }
        Task { await importer.importPicked(urls) }
    }

    enum Strings {
        static let inProgress = LocalizedStringResource(
            "ios.import.inProgress",
            defaultValue: "Adding Music…",
            comment: "Accessibility label shown while audio files import into the library"
        )
    }
}

#Preview {
    ImportButton()
        .environment(AppEnvironment.preview())
}
