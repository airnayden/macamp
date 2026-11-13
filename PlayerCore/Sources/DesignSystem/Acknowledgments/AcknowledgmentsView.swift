import SwiftUI

/// A reusable, scrollable list of the third-party components a build bundles, with
/// each component's license and a link to its project. Token-styled so both the
/// macOS Settings pane and the iOS Settings screen present it identically.
public struct AcknowledgmentsView: View {
    private let entries: [Acknowledgment]

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    public init(entries: [Acknowledgment] = Acknowledgments.core) {
        self.entries = entries
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tokens.spacing.large) {
                header
                VStack(alignment: .leading, spacing: tokens.spacing.large) {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
            }
            .padding(tokens.spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            Text(DesignSystemStrings.acknowledgmentsTitle)
                .font(tokens.typography.titleLarge.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Text(DesignSystemStrings.acknowledgmentsIntro)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ entry: Acknowledgment) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
                Text(verbatim: entry.name)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                if let version = entry.version {
                    Text(verbatim: version)
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                }
                Spacer(minLength: tokens.spacing.small)
                Text(verbatim: entry.license)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.accent.resolve(scheme))
                    .multilineTextAlignment(.trailing)
            }
            Text(verbatim: entry.role)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
            if let address = entry.url, let destination = URL(string: address) {
                Link(destination: destination) {
                    Text(DesignSystemStrings.acknowledgmentsLearnMore)
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.accent.resolve(scheme))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    AcknowledgmentsView(entries: Acknowledgments.core + Acknowledgments.macOS)
        .designTokens(.standard)
}
