import DesignSystem
import SwiftUI

struct InfoSheetView: View {
    let title: String
    let info: String?
    let tags: [String]
    let isLoading: Bool

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.medium) {
            HStack {
                Text(verbatim: title)
                    .font(tokens.typography.titleLarge.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                }
                .buttonStyle(.plain)
            }

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(minHeight: 100)
            } else if let info, !info.isEmpty {
                ScrollView {
                    Text(verbatim: info)
                        .font(tokens.typography.body.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: tokens.spacing.xSmall) {
                            ForEach(tags.prefix(10), id: \.self) { tag in
                                Text(verbatim: tag)
                                    .font(tokens.typography.caption.font)
                                    .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
                                    .padding(.horizontal, tokens.spacing.small)
                                    .padding(.vertical, tokens.spacing.xxSmall)
                                    .background(Capsule().fill(tokens.colors.accent.resolve(scheme).opacity(0.7)))
                            }
                        }
                    }
                }
            } else {
                Text(InfoPanelStrings.noInfo)
                    .font(tokens.typography.body.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            }
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.medium)
        .frame(minWidth: 400, idealWidth: 500, minHeight: 250, idealHeight: 380)
    }
}
