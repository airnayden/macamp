import DesignSystem
import Persistence
import SwiftUI
import ViewModels

struct ArtistLink: View {
    let name: String
    let artistId: Int64?

    @Environment(NavigationModel.self) private var nav
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        if name.isEmpty {
            Text(verbatim: "")
        } else {
            Text(verbatim: name)
                .foregroundStyle(nameColor)
                .underline(isHovered)
                .onHover { hovering in
                    isHovered = hovering
                }
                .pointingHandCursor()
                .onTapGesture {
                    guard let artistId else { return }
                    nav.artistDetail = artistId
                    nav.sidebar = .fixed(.artists)
                }
                .help(name.isEmpty ? Text(verbatim: "") : Text(verbatim: name))
        }
    }

    private var nameColor: Color {
        isHovered ? tokens.colors.accent.resolve(scheme) : tokens.colors.textSecondary.resolve(scheme)
    }
}
