// HygieneDetailRows — what one library-health finding looks like.
//
// Split out of ``HygieneDetailView`` so that file holds only the sheet's chrome and
// its review queue; the switch below is exhaustive with no `default:`, so a fourth
// analyzer cannot ship without a row for it.
//
// Every value that came off the library — a track title, an artist, a genre
// spelling — is `Text(verbatim:)`. Every label around it is a
// ``HygieneDetailStrings`` (or ``ProposalPreviewStrings``) resource.
//
// The Review button is absent, not disabled, for a finding the mapping produced
// nothing for. A greyed button is a promise the surface cannot keep: a duplicate no
// playlist lists twice and a gap with no artist to copy from are worth READING and
// carry no change MacAMP could offer.
import DesignSystem
import Services
import SwiftUI

struct HygieneFindingRow: View {
    let row: HygieneDetailModel.Row
    let review: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: tokens.spacing.small) {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                detail
                if !row.isActionable {
                    caption(HygieneDetailStrings.nothingToApply)
                }
            }
            Spacer(minLength: tokens.spacing.xSmall)
            if row.isActionable {
                reviewButton
            }
        }
        .padding(tokens.spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                .fill(tokens.colors.surfaceRaised.resolve(scheme))
        )
    }
}

// MARK: - Per-finding detail

private extension HygieneFindingRow {
    @ViewBuilder
    var detail: some View {
        switch row.finding {
        case let .duplicate(group): duplicateDetail(group)
        case let .genreCluster(cluster): genreDetail(cluster)
        case let .metadataGap(gap): gapDetail(gap)
        }
    }

    func duplicateDetail(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            headline(Self.displayName(for: group.canonical))
            caption(HygieneDetailStrings.duplicateCopies(count: group.tracks.count))
            caption(
                group.playlistCleanups.isEmpty
                    ? HygieneDetailStrings.duplicateNoPlaylists
                    : HygieneDetailStrings.duplicatePlaylists(count: group.playlistCleanups.count)
            )
        }
    }

    func genreDetail(_ cluster: GenreCluster) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            headline(cluster.canonicalGenre)
            caption(
                HygieneDetailStrings.genreVariants(
                    spellings: cluster.variants.count,
                    tracks: cluster.tracksToRetag.count
                )
            )
            Text(verbatim: cluster.variants.map(\.genre).joined(separator: ", "))
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .lineLimit(2)
        }
    }

    func gapDetail(_ gap: MetadataGap) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            headline(Self.displayName(for: gap.track))
            HStack(spacing: tokens.spacing.xxSmall) {
                Text(HygieneDetailStrings.missingLabel)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                ForEach(gap.missingFields, id: \.self) { field in
                    fieldChip(Self.label(for: field))
                }
            }
        }
    }

    /// The three gap fields reuse the preview sheet's own tag-field labels, so a
    /// finding and the patch it becomes name the same field the same way.
    static func label(for field: MetadataGapField) -> LocalizedStringResource {
        switch field {
        case .genre: ProposalPreviewStrings.fieldGenre
        case .year: ProposalPreviewStrings.fieldYear
        case .albumArtist: ProposalPreviewStrings.fieldAlbumArtist
        }
    }

    static func displayName(for track: HygieneTrack) -> String {
        let title = track.title ?? track.fileURL.lastPathComponent
        guard let artist = track.artistName, !artist.isEmpty else { return title }
        return "\(title) — \(artist)"
    }
}

// MARK: - Shared pieces

private extension HygieneFindingRow {
    func headline(_ text: String) -> some View {
        Text(verbatim: text)
            .font(tokens.typography.headline.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    func caption(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    func fieldChip(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.accent.resolve(scheme))
            .padding(.horizontal, tokens.spacing.xSmall)
            .padding(.vertical, tokens.spacing.xxSmall)
            .background(Capsule().fill(tokens.colors.accentMuted.resolve(scheme)))
    }

    var reviewButton: some View {
        Button(action: review) {
            Text(HygieneDetailStrings.review)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
                .padding(.horizontal, tokens.spacing.small)
                .padding(.vertical, tokens.spacing.xxSmall)
                .background(Capsule().fill(tokens.colors.accent.resolve(scheme)))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(HygieneDetailStrings.reviewHelp)
        .accessibilityLabel(Text(HygieneDetailStrings.review))
        .accessibilityIdentifier("assistant.hygiene.finding.\(row.index).review")
    }
}
