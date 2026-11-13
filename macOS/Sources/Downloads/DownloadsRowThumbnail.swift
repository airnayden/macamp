// DownloadsRowThumbnail — the 32×32 poster frame at the head of every queue row.
//
// ── THE FRAME IS FIXED BEFORE ANYTHING IS KNOWN ─────────────────────────────
//
// The slot occupies its full size from the first body evaluation, whether the row has
// a thumbnail URL, is still fetching one, or will never have one. A slot that grew
// when an image landed would shift every title in the list sideways one row at a time
// as answers trickled in — and the answers arrive over seconds, so it would be a
// visible ripple rather than a single settle. The placeholder is therefore drawn at
// the same size as the image that may replace it.
//
// ── DECORATIVE, SO IT IS HIDDEN FROM VoiceOver ──────────────────────────────
//
// The image says nothing the row's own title and channel do not already say, so it is
// `.accessibilityHidden(true)`: announcing "image" before every download in a fifty-row
// queue is noise, not information.
//
// ── ONE ROW'S OWN `@State`, NOT AN OBSERVABLE MAP ───────────────────────────
//
// The image is awaited through `.task(id:)` and held here, so an arriving thumbnail
// repaints exactly this row. See ``DownloadThumbnailStore`` for why the store itself
// publishes nothing observable.
//
// This file constructs no `Process` and no `URLSession`, and deliberately no
// `AsyncImage` — `macOS/Sources/Downloads` is scanned wholesale by
// `scripts/check-downloader-boundary.sh`, which refuses all three.
import AppKit
import DesignSystem
import Foundation
import SwiftUI

/// A fixed-size, rounded poster frame for one download-queue row.
struct DownloadsRowThumbnail: View {
    /// The poster frame to show, or `nil` while the row has no URL for one yet.
    let url: URL?

    /// The slot's side length. Square, because YouTube poster frames are not — the
    /// image is filled and clipped rather than letterboxed, so every row's leading
    /// edge lines up regardless of the source's aspect ratio.
    static let side: CGFloat = 32

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.downloadThumbnails) private var store
    @State private var image: NSImage?

    var body: some View {
        content
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous))
            .accessibilityHidden(true)
            .task(id: url) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            tokens.colors.surfaceRaised.resolve(scheme)
            Image(systemName: "play.rectangle")
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
    }

    /// Paints a cached frame immediately, otherwise clears and awaits one.
    ///
    /// The cancellation check is what stops a slow answer for the PREVIOUS url landing
    /// on this row after `.task(id:)` has already restarted for a new one — the row
    /// would otherwise show a neighbour's artwork.
    private func load() async {
        guard let url, let store else {
            image = nil
            return
        }
        if let cached = store.cachedImage(for: url) {
            image = cached
            return
        }
        image = nil
        let loaded = await store.image(for: url)
        guard !Task.isCancelled else { return }
        image = loaded
    }
}
