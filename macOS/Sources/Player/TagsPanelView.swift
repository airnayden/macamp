// TagsPanelView — the right-panel "Tags" tab. Shows the ID3 metadata of the
// currently-playing track, loaded as a full `TrackRecord` from the database by the
// player's `currentTrack?.trackID` (a `TrackRef` alone lacks album/genre/year/…).
// Rows whose value is absent are simply not shown; values are copy-selectable.
import DesignSystem
import Persistence
import SwiftUI

struct TagsPanelView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var record: TrackRecord?

    var body: some View {
        Group {
            if let record {
                tagScroll(record)
            } else {
                StateView(
                    systemImage: "tag",
                    title: TagsPanelStrings.emptyTitle,
                    message: TagsPanelStrings.emptyMessage
                )
                .synthwaveEmptyBackground()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: environment.player.currentTrack?.trackID) { await loadRecord() }
    }

    private func tagScroll(_ record: TrackRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tokens.spacing.medium) {
                metadataSection(record)
                audioSection(record)
                fileSection(record)
            }
            .padding(.vertical, tokens.spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Sections

private extension TagsPanelView {
    func metadataSection(_ record: TrackRecord) -> some View {
        section(TagsPanelStrings.sectionMetadata) {
            tagRow(TagsPanelStrings.fieldTitle, record.title)
            tagRow(TagsPanelStrings.fieldArtist, record.artistName)
            tagRow(TagsPanelStrings.fieldAlbum, record.albumTitle)
            tagRow(TagsPanelStrings.fieldAlbumArtist, record.albumArtist)
            tagRow(TagsPanelStrings.fieldGenre, record.genre)
            tagRow(TagsPanelStrings.fieldYear, intText(record.year))
            tagRow(TagsPanelStrings.fieldTrackNumber, intText(record.trackNumber))
            tagRow(TagsPanelStrings.fieldDiscNumber, intText(record.discNumber))
        }
    }

    func audioSection(_ record: TrackRecord) -> some View {
        section(TagsPanelStrings.sectionAudio) {
            tagRow(TagsPanelStrings.fieldBitrate, bitrateText(record))
            tagRow(TagsPanelStrings.fieldSampleRate, sampleRateText(record))
            tagRow(TagsPanelStrings.fieldBitDepth, bitDepthText(record))
            tagRow(TagsPanelStrings.fieldChannels, intText(record.channelCount))
            tagRow(TagsPanelStrings.fieldDuration, durationText(record))
        }
    }

    func fileSection(_ record: TrackRecord) -> some View {
        section(TagsPanelStrings.sectionFile) {
            tagRow(TagsPanelStrings.fieldFilePath, record.filePath)
            tagRow(TagsPanelStrings.fieldFileSize, fileSizeText(record))
        }
    }

    func section(_ header: LocalizedStringResource, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            Text(header)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .textCase(.uppercase)
            rows()
        }
        .padding(.horizontal, tokens.spacing.small)
    }
}

// MARK: - Rows

private extension TagsPanelView {
    @ViewBuilder
    func tagRow(_ label: LocalizedStringResource, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: tokens.spacing.small) {
                Text(label)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .frame(width: 96, alignment: .leading)
                Text(verbatim: value)
                    .font(tokens.typography.body.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, tokens.spacing.xxSmall)
        }
    }
}

// MARK: - Loading + formatting

private extension TagsPanelView {
    func loadRecord() async {
        guard let trackID = environment.player.currentTrack?.trackID else {
            record = nil
            return
        }
        let repository = TrackRepository(environment.database)
        let loaded = try? await Task.detached { try repository.fetchTrack(id: trackID) }.value
        record = loaded ?? nil
    }

    func intText(_ value: Int?) -> String? {
        guard let value else { return nil }
        return "\(value)"
    }

    func bitrateText(_ record: TrackRecord) -> String? {
        guard let bitrate = record.bitrate, bitrate > 0 else { return nil }
        return "\(bitrate / 1000) kbps"
    }

    func sampleRateText(_ record: TrackRecord) -> String? {
        guard let sampleRate = record.sampleRate, sampleRate > 0 else { return nil }
        return String(format: "%.1f kHz", Double(sampleRate) / 1000)
    }

    func bitDepthText(_ record: TrackRecord) -> String? {
        guard let bitDepth = record.bitDepth, bitDepth > 0 else { return nil }
        return "\(bitDepth)-bit"
    }

    func durationText(_ record: TrackRecord) -> String? {
        guard let seconds = record.duration else { return nil }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    func fileSizeText(_ record: TrackRecord) -> String? {
        guard let bytes = record.fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    TagsPanelView()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
        .frame(width: 340, height: 600)
}
