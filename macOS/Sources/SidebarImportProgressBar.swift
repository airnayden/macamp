// SidebarImportProgressBar — the sidebar's bottom-pinned import progress strip.
//
// Hung on the sidebar List through `.safeAreaInset(edge: .bottom)`, so it pins
// below every section without overlapping the folder filter field (which sits at
// the TOP of the Folders section) or any section header, and without joining the
// List's selection.
//
// Visibility is owned ENTIRELY by ``ImportProgressModel/isImporting``, which
// already carries the zero-work guard: a watcher rescan that resolves no
// candidates emits no `.progress` event, so `isImporting` never flips and this
// strip never appears for a no-op pass. There is deliberately no second guard
// here — a redundant one could only ever disagree with the model.
import DesignSystem
import Foundation
import SwiftUI
import ViewModels

// MARK: - Copy

/// Localized copy for the sidebar import-progress strip. The folder NAME is
/// non-translatable and rendered with `Text(verbatim:)` at the call site.
enum SidebarImportProgressStrings {
    /// The determinate tally beneath the bar, e.g. "Importing 3 of 10".
    static func caption(processed: Int, total: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "sidebar.importProgress",
            defaultValue: "Importing \(processed) of \(total)",
            comment: "Sidebar import bar caption; arguments are files done so far and the total"
        )
    }
}

// MARK: - State

/// Pure, view-free projection of ``ImportProgressModel`` for the strip.
///
/// Extracted from the view so the visibility rule and the nil-tolerant folder
/// caption are unit-testable without hosting SwiftUI.
struct SidebarImportProgressState: Equatable {
    /// Whether the strip renders at all. Mirrors ``ImportProgressModel/isImporting``
    /// verbatim, so the model's zero-work guard is the only guard.
    let isVisible: Bool
    let processed: Int
    let total: Int
    /// Completion in `0...1`. Recomputed with the same formula as
    /// ``ImportProgressModel/fraction``; `fractionMatchesTheModel` pins them together.
    let fraction: Double
    /// The last folder handled, or `nil`. `currentPath` is frequently absent —
    /// `FakeLibraryScanner` never sets it and a real chunk can end without one —
    /// so the caption must tolerate its absence rather than render an empty row.
    let folderName: String?

    init(isImporting: Bool, processed: Int, total: Int, currentPath: String?) {
        isVisible = isImporting
        self.processed = processed
        self.total = total
        fraction = total > 0 ? Double(processed) / Double(total) : 0
        folderName = Self.folderName(from: currentPath)
    }

    /// `@MainActor` because it reads main-actor view-model state; a plain struct
    /// init is nonisolated and would not compile.
    @MainActor
    init(model: ImportProgressModel) {
        self.init(
            isImporting: model.isImporting,
            processed: model.processed,
            total: model.total,
            currentPath: model.currentPath
        )
    }

    private static func folderName(from path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

// MARK: - View

/// A leaf that reads the import model itself, so a chunk update re-renders this
/// strip alone instead of the whole sidebar (SKILL macOS UI perf rule 3 — scope
/// cadence reads into a leaf). Renders nothing at all while idle.
struct SidebarImportProgressBar: View {
    let progress: ImportProgressModel

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let state = SidebarImportProgressState(model: progress)
        if state.isVisible {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                ProgressView(value: state.fraction)
                    .progressViewStyle(.linear)
                    .tint(tokens.colors.accent.resolve(scheme))
                Text(SidebarImportProgressStrings.caption(processed: state.processed, total: state.total))
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                if let folderName = state.folderName {
                    Text(verbatim: folderName)
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, tokens.spacing.small)
            .padding(.vertical, tokens.spacing.xSmall)
            .background(tokens.colors.surface.resolve(scheme))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(tokens.colors.separator.resolve(scheme))
                    .frame(height: tokens.spacing.hairline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebar.importProgress")
        }
    }
}
