// TagEditorSheet — the macOS tag-editor surface (single + batch).
//
// A DesignSystem-tokened `Form` bound to ``TagEditorViewModel``. It edits the
// nine scalar tag fields plus embedded artwork, supports a batch of N tracks with
// "(Multiple Values)" placeholders for fields the selection disagrees on, and
// writes only the fields the user actually changed. When NONE of the selected
// file(s) can be written the editor shows a "Read-only source" banner and
// disables Save.
//
// All copy flows through ``MacAMPStrings`` (never a bare literal); DATA the user
// owns (the field text) uses `Text(verbatim:)` only where rendered as a label.
// Artwork is decoded to a `CGImage` via ImageIO (``AlbumArtImage``, no `NSImage`);
// the replace flow uses an AppKit open panel (``TagArtworkPanel``) and a Finder
// drag-on drop. The sheet is a fixed-size macOS panel (header / form / footer),
// the shell's established sheet shape.
import CoreGraphics
import DesignSystem
import Persistence
import SwiftUI
import ViewModels

/// The tag-editor sheet for one or more tracks.
struct TagEditorSheet: View {
    let records: [TrackRecord]

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var model: TagEditorViewModel?
    @State private var showsResultAlert = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 540, height: 600)
        .task { await start() }
        .alert(Text(MacAMPStrings.tagsResultTitle), isPresented: $showsResultAlert) {
            Button { dismiss() } label: { Text(MacAMPStrings.tagsResultDismiss) }
        } message: {
            resultSummary
        }
    }
}

// MARK: - Chrome (header + footer)

private extension TagEditorSheet {
    var header: some View {
        HStack {
            Text(headerTitle)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Spacer()
            autoFillControl
        }
        .padding(tokens.spacing.large)
    }

    @ViewBuilder
    var autoFillControl: some View {
        if records.count == 1, let model {
            if model.isAutoFilling {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await performAutoFill() } } label: {
                    Label(MacAMPStrings.tagsAutoFill, systemImage: "wand.and.stars")
                }
                .disabled(model.isReadOnly)
                .help(Text(MacAMPStrings.tagsAutoFillHelp))
            }
        }
    }

    var footer: some View {
        HStack(spacing: tokens.spacing.small) {
            Spacer()
            Button(role: .cancel) { dismiss() } label: {
                Text(MacAMPStrings.tagsCancel)
            }
            .keyboardShortcut(.cancelAction)
            saveButton
        }
        .padding(tokens.spacing.large)
    }

    @ViewBuilder
    var saveButton: some View {
        if model?.phase == .saving {
            ProgressView().controlSize(.small)
        } else {
            Button { Task { await performSave() } } label: {
                Text(MacAMPStrings.tagsSave)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!(model?.canSave ?? false))
        }
    }

    var headerTitle: LocalizedStringResource {
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

// MARK: - Content

private extension TagEditorSheet {
    @ViewBuilder
    var content: some View {
        if let model {
            form(model)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func form(_ model: TagEditorViewModel) -> some View {
        Form {
            if model.isReadOnly { readOnlyBanner }
            detailsSection(model)
            numberingSection(model)
            artworkSection(model)
        }
        .formStyle(.grouped)
        .disabled(model.phase == .saving)
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
            textRow(model, .year, label: MacAMPStrings.tagsFieldYear)
            textRow(model, .trackNumber, label: MacAMPStrings.tagsFieldTrackNumber)
            textRow(model, .discNumber, label: MacAMPStrings.tagsFieldDiscNumber)
        } header: {
            Text(MacAMPStrings.tagsSectionNumbering)
        }
    }

    func textRow(
        _ model: TagEditorViewModel,
        _ field: TagField,
        label: LocalizedStringResource
    ) -> some View {
        let state = model.form.fields[field]
        return TextField(text: fieldBinding(model, field), prompt: prompt(state, label: label)) {
            Text(label)
        }
        .font(tokens.typography.body.font)
        .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
    }
}

// MARK: - Artwork

private extension TagEditorSheet {
    func artworkSection(_ model: TagEditorViewModel) -> some View {
        Section {
            HStack(spacing: tokens.spacing.medium) {
                artworkThumbnail(model)
                VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                    Button { replaceFromPanel(model) } label: {
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
                Spacer(minLength: 0)
            }
            Text(model.isBatch ? MacAMPStrings.tagsArtworkBatchNote : MacAMPStrings.tagsArtworkDropHint)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        } header: {
            Text(MacAMPStrings.tagsSectionArtwork)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleArtworkDrop(urls, model: model)
        }
    }

    @ViewBuilder
    func artworkThumbnail(_ model: TagEditorViewModel) -> some View {
        let side: CGFloat = 80
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

    func replaceFromPanel(_ model: TagEditorViewModel) {
        guard let data = TagArtworkPanel.chooseImageData(), ArtworkMIME.isImage(data) else { return }
        model.replaceArtwork(data: data, mimeType: ArtworkMIME.sniff(data))
    }

    /// Reads the first dropped image file (Finder provides file URLs) and replaces
    /// the artwork. Bounded read of a small cover file on the main actor.
    func handleArtworkDrop(_ urls: [URL], model: TagEditorViewModel) -> Bool {
        guard !model.isReadOnly else { return false }
        for url in urls {
            guard let data = try? Data(contentsOf: url), ArtworkMIME.isImage(data) else { continue }
            model.replaceArtwork(data: data, mimeType: ArtworkMIME.sniff(data))
            return true
        }
        return false
    }
}

// MARK: - Lifecycle + bindings

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

    func performAutoFill() async {
        guard let model else { return }
        let matched = await model.autoFill()
        if !matched {
            environment.toast.show(
                text: String(localized: MacAMPStrings.tagsAutoFillNoMatch),
                icon: "magnifyingglass"
            )
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

// MARK: - Previews (pure model self-check + editor)

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
        .frame(width: 420, height: 260)
    }

    #Preview("Tag editor") {
        TagEditorSheet(records: [TrackRecord(filePath: "/music/song.flac")])
            .environment(AppEnvironment.preview())
            .designTokens(.standard)
    }
#endif
