// TagEditorSheet — the iOS tag-editor surface (single + batch).
//
// A DesignSystem-tokened `Form` bound to ``TagEditorViewModel``. It edits the
// nine scalar tag fields plus embedded artwork, supports a batch of N tracks with
// "(Multiple Values)" placeholders for fields the selection disagrees on, and
// writes only the fields the user actually changed. When the selected file(s)
// lack a security-scoped bookmark the editor shows a "Read-only source" banner
// and disables Save (the iOS sandbox gate).
//
// All copy flows through ``MacAMPStrings`` (never a bare literal); DATA the user
// owns (the field text) uses `Text(verbatim:)` only where it is rendered as a
// label. Artwork is decoded to a `CGImage` via ImageIO (no UIKit), and the
// replace flow uses PhotosUI. AppKit-free.
import CoreGraphics
import DesignSystem
import Persistence
import PhotosUI
import SwiftUI
import ViewModels

/// The tag-editor sheet for one or more tracks.
struct TagEditorSheet: View {
    let records: [TrackRecord]
    var autoFillOnOpen = false

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var model: TagEditorViewModel?
    @State private var pickedItem: PhotosPickerItem?
    @State private var showsResultAlert = false
    @State private var autoFillNoMatch = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    form(model)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(Text(navigationTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { cancelButton }
                ToolbarItem(placement: .topBarTrailing) { saveButton }
            }
        }
        .task { await start() }
        .onChange(of: pickedItem) { _, item in Task { await loadPicked(item) } }
        .alert(Text(MacAMPStrings.tagsResultTitle), isPresented: $showsResultAlert) {
            Button { dismiss() } label: { Text(MacAMPStrings.done) }
        } message: {
            resultSummary
        }
    }
}

// MARK: - Lifecycle

private extension TagEditorSheet {
    func start() async {
        if model == nil {
            model = TagEditorViewModel(
                records: records,
                database: environment.database,
                metadataFetcher: environment.metadataFetcher
            )
        }
        await model?.load()
        if autoFillOnOpen, records.count == 1, model?.isReadOnly == false {
            await performAutoFill()
        }
    }

    func performAutoFill() async {
        guard let model else { return }
        autoFillNoMatch = false
        let matched = await model.autoFill()
        autoFillNoMatch = !matched
    }

    func performSave() async {
        guard let model else { return }
        await model.save()
        if model.results.contains(where: \.isFailure) {
            showsResultAlert = true
        } else {
            dismiss()
        }
    }

    func loadPicked(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        model?.replaceArtwork(data: data, mimeType: ArtworkMIME.sniff(data))
    }

    var navigationTitle: LocalizedStringResource {
        records.count > 1
            ? MacAMPStrings.tagsEditorTitleMulti(records.count)
            : MacAMPStrings.tagsEditorTitleSingle
    }

    var resultSummary: Text {
        guard let model else { return Text(verbatim: "") }
        let failed = model.results.filter(\.isFailure).count
        let succeeded = model.results.count - failed
        return Text(MacAMPStrings.tagsResultMessage(succeeded: succeeded, failed: failed))
    }
}

// MARK: - Form

private extension TagEditorSheet {
    func form(_ model: TagEditorViewModel) -> some View {
        Form {
            if model.isReadOnly { readOnlyBanner }
            autoFillSection(model)
            detailsSection(model)
            numberingSection(model)
            artworkSection(model)
        }
        .disabled(model.phase == .saving)
    }

    @ViewBuilder
    func autoFillSection(_ model: TagEditorViewModel) -> some View {
        if records.count == 1 {
            Section {
                if model.isAutoFilling {
                    HStack(spacing: tokens.spacing.small) {
                        ProgressView()
                        Text(MacAMPStrings.tagsAutoFillBusy)
                            .font(tokens.typography.body.font)
                            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    }
                } else {
                    Button { Task { await performAutoFill() } } label: {
                        Label { Text(MacAMPStrings.tagsAutoFill) } icon: { Image(systemName: "wand.and.stars") }
                    }
                    .disabled(model.isReadOnly)
                    .accessibilityHint(Text(MacAMPStrings.tagsAutoFillHint))
                }
                if autoFillNoMatch {
                    Text(MacAMPStrings.tagsAutoFillNoMatch)
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                }
            }
        }
    }

    var readOnlyBanner: some View {
        Section {
            HStack(alignment: .top, spacing: tokens.spacing.small) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(tokens.colors.warning.resolve(scheme))
                VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                    Text(MacAMPStrings.tagsReadOnlyBadge)
                        .font(tokens.typography.headline.font)
                        .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    Text(MacAMPStrings.tagsReadOnlyMessage)
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                }
            }
        }
    }

    func detailsSection(_ model: TagEditorViewModel) -> some View {
        Section {
            textRow(model, .title, label: MacAMPStrings.tagsFieldTitle)
            textRow(model, .artist, label: MacAMPStrings.tagsFieldArtist)
            textRow(model, .album, label: MacAMPStrings.tagsFieldAlbum)
            textRow(model, .albumArtist, label: MacAMPStrings.tagsFieldAlbumArtist)
            textRow(model, .genre, label: MacAMPStrings.tagsFieldGenre)
            textRow(model, .composer, label: MacAMPStrings.tagsFieldComposer)
        } header: {
            Text(MacAMPStrings.tagsSectionDetails)
        }
    }

    func numberingSection(_ model: TagEditorViewModel) -> some View {
        Section {
            textRow(model, .year, label: MacAMPStrings.tagsFieldYear, numeric: true)
            textRow(model, .trackNumber, label: MacAMPStrings.tagsFieldTrackNumber, numeric: true)
            textRow(model, .discNumber, label: MacAMPStrings.tagsFieldDiscNumber, numeric: true)
        } header: {
            Text(MacAMPStrings.tagsSectionNumbering)
        }
    }

    @ViewBuilder
    func textRow(
        _ model: TagEditorViewModel,
        _ field: TagField,
        label: LocalizedStringResource,
        numeric: Bool = false
    ) -> some View {
        let state = model.form.fields[field]
        TextField(text: fieldBinding(model, field), prompt: prompt(state, label: label)) {
            Text(label)
        }
        .font(tokens.typography.body.font)
        .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
        .keyboardType(numeric ? .numbersAndPunctuation : .default)
        .textInputAutocapitalization(numeric ? .never : .words)
        .disableAutocorrection(numeric)
    }
}

// MARK: - Artwork

private extension TagEditorSheet {
    func artworkSection(_ model: TagEditorViewModel) -> some View {
        Section {
            HStack(spacing: tokens.spacing.medium) {
                artworkThumbnail(model)
                VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                    PhotosPicker(selection: $pickedItem, matching: .images) {
                        Text(MacAMPStrings.tagsArtworkReplace)
                    }
                    .disabled(model.isReadOnly)
                    Button(role: .destructive) {
                        model.removeArtwork()
                    } label: {
                        Text(MacAMPStrings.tagsArtworkRemove)
                    }
                    .disabled(model.isReadOnly)
                }
            }
            if model.isBatch {
                Text(MacAMPStrings.tagsArtworkBatchNote)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            } else {
                Text(MacAMPStrings.tagsArtworkDropHint)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
        } header: {
            Text(MacAMPStrings.tagsSectionArtwork)
        }
        .dropDestination(for: Data.self) { items, _ in
            guard let data = items.first(where: ArtworkMIME.isImage) else { return false }
            model.replaceArtwork(data: data, mimeType: ArtworkMIME.sniff(data))
            return true
        }
    }

    @ViewBuilder
    func artworkThumbnail(_ model: TagEditorViewModel) -> some View {
        let side: CGFloat = 72
        if let image = model.artworkPreview {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: tokens.radii.small))
        } else {
            RoundedRectangle(cornerRadius: tokens.radii.small)
                .fill(tokens.colors.surfaceRaised.resolve(scheme))
                .frame(width: side, height: side)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                }
                .accessibilityLabel(Text(MacAMPStrings.tagsArtworkNone))
        }
    }
}

// MARK: - Toolbar + bindings

private extension TagEditorSheet {
    var cancelButton: some View {
        Button { dismiss() } label: { Text(MacAMPStrings.tagsCancel) }
    }

    @ViewBuilder
    var saveButton: some View {
        if model?.phase == .saving {
            ProgressView()
        } else {
            Button { Task { await performSave() } } label: { Text(MacAMPStrings.tagsSave) }
                .disabled(!(model?.canSave ?? false))
        }
    }

    func fieldBinding(_ model: TagEditorViewModel, _ field: TagField) -> Binding<String> {
        Binding(
            get: { model.form.fields[field]?.text ?? "" },
            set: { model.setField(field, to: $0) }
        )
    }

    /// A mixed batch field prompts "(Multiple Values)"; otherwise the field label.
    func prompt(_ state: TagFieldState?, label: LocalizedStringResource) -> Text {
        if state?.isMixed == true {
            return Text(MacAMPStrings.tagsMultipleValues)
        }
        return Text(label)
    }
}

// MARK: - Artwork MIME sniffing

/// Detects an image MIME type from leading magic bytes (mirrors the reader's
/// sniffer) so dropped / picked bytes carry a correct type into the tag.
enum ArtworkMIME {
    static func sniff(_ data: Data) -> String? {
        let prefix = [UInt8](data.prefix(4))
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if prefix.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        return nil
    }

    static func isImage(_ data: Data) -> Bool {
        sniff(data) != nil
    }
}

// MARK: - Self-check preview (pure model verification)

#if DEBUG
    #Preview("Tag model self-check") {
        List(TagFormSelfCheck.run(), id: \.name) { outcome in
            HStack {
                Image(systemName: outcome.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(outcome.passed ? Color.green : Color.red)
                Text(verbatim: outcome.name)
                Spacer()
                Text(verbatim: outcome.passed ? "PASS" : "FAIL")
                    .fontWeight(.semibold)
            }
        }
    }

    #Preview("Tag editor") {
        let sampleTitle = "Untitled"
        return TagEditorSheet(records: [TrackRecord(filePath: "/music/song.flac", title: sampleTitle)])
            .environment(AppEnvironment.preview())
            .designTokens(.standard)
    }
#endif
