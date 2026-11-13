// LibraryChatWebPointer — the one line that tells an on-device listener why the web
// suggestions they switched on are not appearing.
//
// ── THE BANNER IS THE HONEST HALF OF A CLOUD-ONLY GRANT ─────────────────────
//
// `AppEnvironment+WebSuggestions` refuses BOTH halves of the grant to the on-device
// tier — no web tool, no link lookup — because that tier's whole promise is that
// nothing leaves the Mac. From the listener's side that refusal is indistinguishable
// from a broken feature: the switch is on, the disclosure was accepted, and no links
// appear. This row is what closes that gap, and it points at the one place the
// choice can be changed rather than merely reporting a state.
//
// It is shown ONLY on the on-device route. On a cloud route the feature is working,
// and a pointer at it would be a lie about it; with no route at all
// `LibraryChatNoticeView` already owns the explanation.
//
// ── DISMISSAL IS SESSION STATE, DELIBERATELY NOT A DEFAULTS KEY ─────────────
//
// Three statements, pinned by `LibraryChatSuggestionLinkTests`:
//
//   dismiss              -> hidden
//   `LibraryChatViewModel.reset()`  -> STILL hidden
//   a new launch         -> shown again
//
// The last is why there is no `UserDefaults` key: a persisted flag makes a new
// instance start dismissed, which turns "not now" into "never" for a notice whose
// whole purpose is to be re-read after the listener forgets why links stopped
// appearing. And the middle one is why this state does not live on the chat view
// model: `reset()` clears the transcript AND the tier's history, and a notice the
// listener already closed is neither.
import DesignSystem
import Services
import SwiftUI

/// Whether the on-device web-suggestions pointer should be drawn, for this launch.
@MainActor
@Observable
final class LibraryChatWebPointer {
    private(set) var isDismissed = false

    func dismiss() {
        isDismissed = true
    }

    /// The triple condition — an on-device conversation, the switch, the disclosure
    /// — and then the listener's own dismissal.
    ///
    /// The two records are read through ``AppSettings/webSuggestionsGrant``, which is
    /// the ONE place they are combined, so this surface cannot come to a different
    /// answer than the composition root that withheld the feature.
    func isVisible(route: LibraryChatRoute?, settings: AppSettings) -> Bool {
        guard !isDismissed, settings.webSuggestionsGrant else { return false }
        return route == .appleIntelligence
    }
}

// MARK: - The row

/// One dismissible caption, drawn like the transcript's other notices.
struct LibraryChatWebPointerBanner: View {
    let dismiss: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: tokens.spacing.xSmall) {
            Image(systemName: "globe")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .accessibilityHidden(true)
            // The identifier sits on the `Text` rather than on this stack: the row
            // holds an interactive child, so it cannot be collapsed into one
            // accessibility element, and an identifier on a plain container has no
            // element of its own for a UI test to resolve.
            Text(LibraryChatStrings.webPointerMessage)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("assistant.chat.webPointer")
            Spacer(minLength: 0)
            dismissButton
        }
        .padding(tokens.spacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                .fill(tokens.colors.surfaceRaised.resolve(scheme))
        )
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(Text(LibraryChatStrings.webPointerDismiss))
        .accessibilityLabel(Text(LibraryChatStrings.webPointerDismiss))
        .accessibilityIdentifier("assistant.chat.webPointer.dismiss")
    }
}

#Preview {
    LibraryChatWebPointerBanner(dismiss: {})
        .designTokens(.standard)
        .padding()
        .frame(width: 420)
}
