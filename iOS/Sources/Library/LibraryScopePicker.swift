// LibraryScopePicker — the bespoke browse-scope selector for the iOS library.
//
// Replaces the stock `.segmented` Picker with a token-styled segmented control: a
// recessed `surface` track holds three equal-width icon+label segments, and an
// accent-filled indicator slides behind the selected one via `matchedGeometryEffect`.
// Every color, radius, gap, type role and shadow resolves through the design tokens
// — no literal styling — so it inherits the streaming-player visual spine (Task 10).
//
// `LibraryScope` lives here (not in LibraryScreen) so the picker is a self-contained
// component; the screen owns only the `@State` selection it binds.
import DesignSystem
import SwiftUI

/// The three browse scopes of the library.
enum LibraryScope: String, CaseIterable, Identifiable {
    case songs, albums, artists

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .songs: MacAMPStrings.libraryScopeSongs
        case .albums: MacAMPStrings.libraryScopeAlbums
        case .artists: MacAMPStrings.libraryScopeArtists
        }
    }

    var systemImage: String {
        switch self {
        case .songs: "music.note"
        case .albums: "square.stack.fill"
        case .artists: "music.mic"
        }
    }
}

/// A token-styled segmented scope selector with a sliding accent indicator.
struct LibraryScopePicker: View {
    @Binding var selection: LibraryScope

    @Namespace private var indicator
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: tokens.spacing.xxSmall) {
            ForEach(LibraryScope.allCases) { scope in
                segment(scope)
            }
        }
        .padding(tokens.spacing.xxSmall)
        .background(track)
        .accessibilityElement(children: .contain)
    }

    private var track: some View {
        RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
            .fill(tokens.colors.surface.resolve(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
                    .strokeBorder(tokens.colors.separator.resolve(scheme), lineWidth: tokens.spacing.hairline)
            )
    }

    private func segment(_ scope: LibraryScope) -> some View {
        let isSelected = scope == selection
        return Button {
            withAnimation(.snappy(duration: tokens.motion.quick)) {
                selection = scope
            }
        } label: {
            HStack(spacing: tokens.spacing.xxSmall) {
                Image(systemName: scope.systemImage)
                    .imageScale(.small)
                Text(scope.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(tokens.typography.callout.font)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundStyle(foreground(isSelected))
            .frame(maxWidth: .infinity)
            .padding(.vertical, tokens.spacing.xSmall)
            .background(indicatorBackground(isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Text(MacAMPStrings.a11yHintLibraryScope))
    }

    @ViewBuilder
    private func indicatorBackground(_ isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                .fill(tokens.colors.accent.resolve(scheme))
                .shadow(
                    color: .black.opacity(tokens.elevation.low.colorOpacity),
                    radius: tokens.elevation.low.radius,
                    x: tokens.elevation.low.offsetX,
                    y: tokens.elevation.low.offsetY
                )
                .matchedGeometryEffect(id: "scope.indicator", in: indicator)
        }
    }

    private func foreground(_ isSelected: Bool) -> Color {
        (isSelected ? tokens.colors.onAccent : tokens.colors.textSecondary).resolve(scheme)
    }
}

#Preview {
    struct Harness: View {
        @State private var scope: LibraryScope = .songs
        var body: some View {
            LibraryScopePicker(selection: $scope)
                .padding()
                .designTokens(.standard)
        }
    }
    return Harness()
}
