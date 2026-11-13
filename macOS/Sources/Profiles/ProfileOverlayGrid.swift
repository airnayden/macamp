import DesignSystem
import Persistence
import SwiftUI

struct ProfileOverlayGrid: View {
    let profiles: [ProfileRecord]
    let activeProfileId: Int64
    let onSelect: (ProfileRecord) -> Void
    let onEdit: (ProfileRecord) -> Void
    let onCreate: () -> Void

    @Environment(\.designTokens) private var tokens

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 128), spacing: tokens.spacing.medium)]
        LazyVGrid(columns: columns, spacing: tokens.spacing.xLarge) {
            ForEach(profiles, id: \.id) { profile in
                ProfileTileButton(
                    profile: profile,
                    isActive: profile.id == activeProfileId,
                    onSelect: { onSelect(profile) },
                    onEdit: { onEdit(profile) }
                )
            }
            ProfileCreateTile(action: onCreate)
        }
    }
}

private struct ProfileTileButton: View {
    let profile: ProfileRecord
    let isActive: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    private let avatarSize: CGFloat = 96

    var body: some View {
        ZStack(alignment: .topTrailing) {
            selectButton
            editBadge
        }
        .onHover { isHovering = $0 }
    }

    private var selectButton: some View {
        Button(action: onSelect) {
            VStack(spacing: tokens.spacing.small) {
                avatar
                Text(verbatim: displayName)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(nameColor.resolve(scheme))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profiles.tile.\(profile.id ?? -1)")
        .accessibilityLabel(Text(verbatim: displayName))
    }

    private var avatar: some View {
        ProfileAvatarView(
            preset: ProfileAvatarPreset(id: profile.avatarId),
            imagePath: profile.avatarImagePath,
            size: avatarSize
        )
        .overlay { highlightRing }
        .overlay(alignment: .bottomTrailing) { lockBadge }
    }

    @ViewBuilder private var highlightRing: some View {
        if isActive {
            Circle().strokeBorder(tokens.colors.accent.resolve(scheme), lineWidth: 3)
        } else if isHovering {
            Circle().strokeBorder(tokens.colors.accent.resolve(scheme).opacity(0.5), lineWidth: 2)
        }
    }

    @ViewBuilder private var lockBadge: some View {
        if hasLock {
            Image(systemName: "lock.fill")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
                .padding(tokens.spacing.xSmall)
                .background(Circle().fill(tokens.colors.accent.resolve(scheme)))
                .overlay(Circle().strokeBorder(tokens.colors.surface.resolve(scheme), lineWidth: 2))
                .accessibilityLabel(Text(ProfileStrings.tileLockedLabel))
        }
    }

    private var editBadge: some View {
        Button(action: onEdit) {
            Image(systemName: "pencil")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .padding(tokens.spacing.xSmall)
                .background(Circle().fill(tokens.colors.surfaceRaised.resolve(scheme)))
                .overlay(Circle().strokeBorder(
                    tokens.colors.separator.resolve(scheme),
                    lineWidth: tokens.spacing.hairline
                ))
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0.55)
        .accessibilityIdentifier("profiles.tile.\(profile.id ?? -1).edit")
        .accessibilityLabel(Text(ProfileStrings.overlayEditLabel(profileName: displayName)))
    }

    private var hasLock: Bool {
        profile.pinHash != nil && profile.id != ProfileRecord.guestID
    }

    private var nameColor: AdaptiveColor {
        isActive ? tokens.colors.accent : tokens.colors.textSecondary
    }

    private var displayName: String {
        profile.id == ProfileRecord.guestID ? String(localized: ProfileStrings.guestName) : profile.name
    }
}

private struct ProfileCreateTile: View {
    let action: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    private let avatarSize: CGFloat = 96

    var body: some View {
        Button(action: action) {
            VStack(spacing: tokens.spacing.small) {
                createGlyph
                Text(ProfileStrings.overlayCreate)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("profiles.createTile")
        .accessibilityLabel(Text(ProfileStrings.overlayCreate))
    }

    private var createGlyph: some View {
        ZStack {
            Circle()
                .fill(tokens.colors.surfaceRaised.resolve(scheme).opacity(isHovering ? 0.9 : 0.5))
            Image(systemName: "plus")
                .font(.system(size: avatarSize * 0.4, weight: .semibold))
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
        }
        .frame(width: avatarSize, height: avatarSize)
        .overlay(Circle().strokeBorder(tokens.colors.separator.resolve(scheme), lineWidth: tokens.spacing.hairline))
    }
}
