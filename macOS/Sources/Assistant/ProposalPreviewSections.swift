// ProposalPreviewSections — what each ``AIProposal/Kind`` actually looks like.
//
// Split out of ``ProposalPreviewSheet`` so the sheet file holds only chrome and the
// tag gate; the switch below is exhaustive with no `default:`, so a fifth proposal
// kind cannot ship without a preview for it.
//
// Every value that came out of a generator or off a file is `Text(verbatim:)`;
// every label around it is a ``ProposalPreviewStrings`` resource.
import DesignSystem
import Metadata
import SwiftUI
import ViewModels

struct ProposalPreviewSections: View {
    let proposal: AIProposal
    let model: ProposalPreviewModel

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    /// Ceiling on rows drawn per list. The resolution ceiling
    /// (``ProposalPreviewModel/maxResolvedIds``) is higher, so a capped list is
    /// always capped by choice rather than by a missing title.
    static let maxRows = 100

    var body: some View {
        switch proposal.kind {
        case let .createPlaylist(request): createSection(request)
        case let .organize(_, diff): organizeSection(diff)
        case let .rename(_, name): renameSection(proposedName: name)
        case let .tagChangeSet(patches): tagSection(patches)
        }
    }
}

// MARK: - Create

private extension ProposalPreviewSections {
    @ViewBuilder
    func createSection(_ request: CreatePlaylistRequest) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            fieldLabel(ProposalPreviewStrings.newPlaylistLabel)
            Text(verbatim: request.name)
                .font(tokens.typography.titleLarge.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
            if let summary = request.summary {
                Text(verbatim: summary)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if request.querySpec?.lowConfidence == true {
                Text(ProposalPreviewStrings.lowConfidence)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.warning.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        trackList(ProposalPreviewStrings.tracksSection, request.orderedTrackIds)
    }
}

// MARK: - Organize

private extension ProposalPreviewSections {
    @ViewBuilder
    func organizeSection(_ diff: PlaylistOrganizeDiff) -> some View {
        if diff.isEmpty {
            Text(ProposalPreviewStrings.noChanges)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
        } else {
            trackList(ProposalPreviewStrings.additionsSection, diff.additions, badge: "plus")
            trackList(ProposalPreviewStrings.removalsSection, diff.removals, badge: "minus")
            trackList(ProposalPreviewStrings.movesSection, diff.moves, badge: "arrow.up.arrow.down")
        }
    }
}

// MARK: - Rename

private extension ProposalPreviewSections {
    func renameSection(proposedName: String) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.small) {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                fieldLabel(ProposalPreviewStrings.renameCurrentLabel)
                Text(verbatim: model.currentPlaylistName ?? "—")
                    .font(tokens.typography.body.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .strikethrough(model.currentPlaylistName != nil)
            }
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                fieldLabel(ProposalPreviewStrings.renameProposedLabel)
                Text(verbatim: proposedName)
                    .font(tokens.typography.titleMedium.font)
                    .foregroundStyle(tokens.colors.accent.resolve(scheme))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Tags

private extension ProposalPreviewSections {
    func tagSection(_ patches: [TagPatch]) -> some View {
        let listed = Array(patches.prefix(Self.maxRows))
        return VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            selectableHeader(ProposalPreviewStrings.tagsSection, trackIds: listed.map(\.trackId))
            ForEach(Array(listed.enumerated()), id: \.offset) { _, patch in
                tagPatchRow(patch)
            }
        }
    }

    func tagPatchRow(_ patch: TagPatch) -> some View {
        HStack(alignment: .top, spacing: tokens.spacing.xSmall) {
            includeToggle(patch.trackId)
            tagPatchFields(patch)
        }
        .padding(tokens.spacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .opacity(model.isIncluded(patch.trackId) ? 1 : excludedRowOpacity)
    }

    func tagPatchFields(_ patch: TagPatch) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            Text(verbatim: patch.fileURL.lastPathComponent)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
            let rows = Self.changes(in: patch.patch)
            if rows.isEmpty {
                fieldLabel(ProposalPreviewStrings.fieldsUnchanged)
            } else {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xxSmall) {
                        fieldLabel(row.label)
                        if let value = row.value {
                            Text(verbatim: value)
                                .font(tokens.typography.callout.font)
                                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A table rather than a chain of `if let`s: ten branches would breach the
    /// `cyclomatic_complexity` budget, and a table also fixes the display order.
    static func changes(in patch: WritableMetadata) -> [TagChangeRow] {
        let scalars: [(LocalizedStringResource, String?)] = [
            (ProposalPreviewStrings.fieldTitle, patch.title),
            (ProposalPreviewStrings.fieldArtist, patch.artist),
            (ProposalPreviewStrings.fieldAlbum, patch.album),
            (ProposalPreviewStrings.fieldAlbumArtist, patch.albumArtist),
            (ProposalPreviewStrings.fieldGenre, patch.genre),
            (ProposalPreviewStrings.fieldComposer, patch.composer),
            (ProposalPreviewStrings.fieldYear, patch.year.map(String.init)),
            (ProposalPreviewStrings.fieldTrackNumber, patch.trackNumber.map(String.init)),
            (ProposalPreviewStrings.fieldDiscNumber, patch.discNumber.map(String.init)),
        ]
        var rows = scalars.compactMap { label, value in
            value.map { TagChangeRow(label: label, value: $0) }
        }
        if let artwork = patch.artwork {
            rows.append(TagChangeRow(
                label: artwork.isEmpty
                    ? ProposalPreviewStrings.fieldArtworkRemoved
                    : ProposalPreviewStrings.fieldArtworkReplaced,
                value: nil
            ))
        }
        return rows
    }
}

/// One "field: new value" line inside a tag patch row.
struct TagChangeRow: Identifiable {
    let label: LocalizedStringResource
    let value: String?

    var id: String {
        label.key
    }
}

// MARK: - Shared pieces

private extension ProposalPreviewSections {
    @ViewBuilder
    func trackList(
        _ title: LocalizedStringResource,
        _ trackIds: [Int64],
        badge: String? = nil
    ) -> some View {
        if !trackIds.isEmpty {
            let listed = Array(trackIds.prefix(Self.maxRows))
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                selectableHeader(title, trackIds: listed)
                ForEach(Array(listed.enumerated()), id: \.offset) { index, trackId in
                    trackRow(position: index + 1, trackId: trackId, badge: badge)
                }
            }
        }
    }

    func trackRow(position: Int, trackId: Int64, badge: String?) -> some View {
        HStack(spacing: tokens.spacing.xSmall) {
            includeToggle(trackId)
            trackRowSummary(position: position, trackId: trackId, badge: badge)
        }
        .padding(.horizontal, tokens.spacing.xSmall)
        .padding(.vertical, tokens.spacing.xxSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .opacity(model.isIncluded(trackId) ? 1 : excludedRowOpacity)
    }

    /// The row's informational half — position/badge plus the resolved title — as ONE
    /// accessibility element.
    ///
    /// GROUPED, COMBINED AND NAMED ON PURPOSE — all three modifiers are load-bearing.
    ///
    /// A row of bare `Text`s merges into ONE element; putting a control (the include
    /// checkbox) in the same layout-only `HStack` stops that merge and leaves each
    /// `Text` as its own element. Worse, a SwiftUI `Text` publishes its string as
    /// `AXValue` and leaves `AXTitle` EMPTY — measured, not assumed — so the row had no
    /// accessible NAME at all. The raw AXUIElement tree still prints the strings, which
    /// is why the loss is invisible to a `System Events` probe; XCUITest matches on
    /// `label`, and VoiceOver announces a nameless static text.
    ///
    /// `.combine` puts the row back to one element, and an explicit
    /// `.accessibilityLabel` is the only thing that fills `AXTitle`. The sheet's tag
    /// rows never regressed because their text already sat one level deeper inside a
    /// `VStack`, which kept merging.
    func trackRowSummary(position: Int, trackId: Int64, badge: String?) -> some View {
        HStack(spacing: tokens.spacing.xSmall) {
            if let badge {
                Image(systemName: badge)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.accent.resolve(scheme))
                    .frame(width: badgeWidth)
            } else {
                Text(verbatim: "\(position)")
                    .font(tokens.typography.caption.font)
                    .monospacedDigit()
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .frame(width: badgeWidth, alignment: .trailing)
            }
            resolvedTitle(trackId)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowName(trackId))
    }

    /// The row's spoken name: the resolved title, or the localized placeholder for a
    /// track whose library row could not be resolved. The leading position digit and
    /// the add/remove/move badge are deliberately left out — the list position and the
    /// section header already carry both.
    func rowName(_ trackId: Int64) -> Text {
        guard let title = model.title(for: trackId) else {
            return Text(ProposalPreviewStrings.unknownTrack)
        }
        return Text(verbatim: title)
    }

    @ViewBuilder
    func resolvedTitle(_ trackId: Int64) -> some View {
        if let title = model.title(for: trackId) {
            Text(verbatim: title)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
        } else {
            Text(ProposalPreviewStrings.unknownTrack)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .lineLimit(1)
        }
    }

    func sectionHeader(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(tokens.typography.caption.font)
            .textCase(.uppercase)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
    }

    /// A section header with its own Select All / Deselect All pair.
    ///
    /// `trackIds` is the LISTED slice, never the whole proposal: unticking a row the
    /// sheet never drew would be invisible, and the truncation caption promises the
    /// opposite.
    func selectableHeader(_ title: LocalizedStringResource, trackIds: [Int64]) -> some View {
        HStack(spacing: tokens.spacing.xSmall) {
            sectionHeader(title)
            Spacer(minLength: tokens.spacing.xxSmall)
            selectionButton(ProposalPreviewStrings.selectAll, section: title, trackIds: trackIds, included: true)
            selectionButton(ProposalPreviewStrings.deselectAll, section: title, trackIds: trackIds, included: false)
        }
    }

    func selectionButton(
        _ label: LocalizedStringResource,
        section: LocalizedStringResource,
        trackIds: [Int64],
        included: Bool
    ) -> some View {
        Button { model.setIncluded(included, for: trackIds) } label: {
            Text(label)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("assistant.proposalSection.\(section.key).\(included ? "selectAll" : "deselectAll")")
    }

    /// The per-row tick. A native `.checkbox` toggle rather than a drawn glyph, so it
    /// inherits the platform's own hit target, focus ring and VoiceOver contract.
    func includeToggle(_ trackId: Int64) -> some View {
        Toggle(isOn: Binding(
            get: { model.isIncluded(trackId) },
            set: { model.setIncluded($0, for: trackId) }
        )) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .pointingHandCursor()
            .help(ProposalPreviewStrings.includeTrack)
            .accessibilityLabel(Text(ProposalPreviewStrings.includeTrack))
            .accessibilityIdentifier("assistant.proposalTrack.\(trackId).included")
    }

    var excludedRowOpacity: Double {
        0.45
    }

    func fieldLabel(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
    }

    var rowBackground: some View {
        RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
            .fill(tokens.colors.surfaceRaised.resolve(scheme))
    }

    var badgeWidth: CGFloat {
        tokens.spacing.large
    }
}
