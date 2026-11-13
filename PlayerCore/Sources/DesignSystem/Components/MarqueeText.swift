// MarqueeText — a single-line label that slides its own text when it overflows.
//
// A drop-in replacement for a plain `Text(verbatim:)` title: it lays out exactly
// like one (natural height, at most its ideal width, tail-truncated) and only
// starts sliding once three conditions hold at the same time — the text really is
// wider than the space it got, motion is allowed, and the caller says the surface
// is ACTIVE.
//
// `isActive` is the idle-CPU seam. Callers gate it on playback
// (`environment.player.isPlaying`), so a paused app animates nothing at all and
// idle CPU stays ≈0% (SKILL.md performance budget). Precedent: `ActiveTick` /
// `TickPolicy`, the playback-gated ticker in this same folder.
//
// The scroll is CA-driven: ONE `withAnimation(.linear(…).repeatForever(…))`
// commits a single offset change, and the render server interpolates it from then
// on. The SwiftUI body is NOT re-evaluated per frame — there is deliberately no
// `TimelineView` and no `Timer` anywhere in this file (macOS UI performance rule 2:
// a SwiftUI redraw loop re-enters the window's layout pass on every tick).
//
// Reduce-motion arrives through `\.themePresentation`, the SAME shell-injected
// presentation token `ThemedBackground` reads — PlayerCore cannot query AppKit /
// UIKit accessibility settings itself, and must never import them.
//
// The animate / don't-animate decision lives in `MarqueeLayout`, a plain caseless
// enum, NOT on the view. `SwiftUI.View` is a `@MainActor` protocol, so every member
// of a conforming type (statics included) inherits main-actor isolation and a
// nonisolated unit test would TRAP at runtime instead of failing to compile.
// Keeping the rule off the view is what makes it directly assertable.
import CoreGraphics
import SwiftUI

/// Pure, SwiftUI-free decision logic for a marquee label.
///
/// A caseless-enum namespace so the scroll rule can be unit-tested directly — no
/// SwiftUI host, no layout pass, no wall-clock timing. ``MarqueeText`` is a thin
/// wrapper over it.
public enum MarqueeLayout {
    /// Sub-pixel slack, in points, before text counts as overflowing.
    ///
    /// Text measurement routinely lands a hair over the available width for a
    /// string that visually fits; without this a "0.0001 pt overflow" would scroll
    /// a label that has nothing to reveal.
    public static let overflowTolerance: CGFloat = 0.5

    /// Whether the label should scroll its text rather than truncate it.
    ///
    /// `true` ONLY when the caller reports the surface active, motion is allowed,
    /// and the text is genuinely wider than the space it was given. Any
    /// non-finite or zero-width measurement (the state before the first layout
    /// pass) is treated as "not overflowing" so a freshly mounted label never
    /// animates on garbage geometry.
    public static func shouldAnimate(
        textWidth: CGFloat,
        containerWidth: CGFloat,
        reduceMotion: Bool,
        isActive: Bool
    ) -> Bool {
        guard isActive, !reduceMotion else { return false }
        guard textWidth.isFinite, containerWidth.isFinite, containerWidth > 0 else { return false }
        return textWidth > containerWidth + overflowTolerance
    }

    /// Points the text travels per second. A readable Winamp-ish crawl: slow
    /// enough to finish a long title, fast enough not to feel stalled.
    static let scrollSpeed: CGFloat = 30

    /// Floor for a cycle, so a barely-overflowing title cannot flick past.
    static let minimumScrollDuration: Double = 1

    /// Seconds one full cycle takes — proportional to how far the text travels,
    /// so every title scrolls at the same apparent speed regardless of length.
    static func scrollDuration(distance: CGFloat) -> Double {
        guard distance.isFinite, distance > 0 else { return minimumScrollDuration }
        return max(Double(distance / scrollSpeed), minimumScrollDuration)
    }
}

/// A single-line label that slides overflowing text horizontally while active.
///
/// Renders a static, tail-truncated `Text` whenever ``MarqueeLayout`` says no —
/// text that fits, reduce-motion, or `isActive == false` — and otherwise overlays
/// a seamlessly looping two-copy track clipped to the label's own bounds. Layout
/// is identical in both cases, so toggling never nudges neighbouring views.
public struct MarqueeText: View {
    private let text: String
    private let font: Font
    private let color: Color
    private let isActive: Bool

    @Environment(\.designTokens) private var tokens
    @Environment(\.themePresentation) private var presentation

    /// Ideal width of the whole string, from the hidden sizing probe.
    @State private var textWidth: CGFloat = 0
    /// Width the label was actually laid out at.
    @State private var containerWidth: CGFloat = 0

    public init(text: String, font: Font, color: Color, isActive: Bool) {
        self.text = text
        self.font = font
        self.color = color
        self.isActive = isActive
    }

    public var body: some View {
        staticLabel
            // Kept in the tree (never `.hidden()`) so it goes on defining the
            // label's width, its height, and its accessibility element.
            .opacity(isAnimating ? 0 : 1)
            .background(alignment: .leading) { sizingProbe }
            .background { containerProbe }
            .overlay(alignment: .leading) { scrollingTrack }
            .marqueeClipped(isAnimating)
            .accessibilityLabel(Text(verbatim: text))
    }

    private var isAnimating: Bool {
        MarqueeLayout.shouldAnimate(
            textWidth: textWidth,
            containerWidth: containerWidth,
            reduceMotion: presentation.reduceMotion,
            isActive: isActive
        )
    }

    /// Gap between the two copies of the text, off the 4-pt spacing grid.
    private var gap: CGFloat {
        tokens.spacing.xxLarge
    }

    /// How far the track travels before it lands exactly where it started.
    private var cycleDistance: CGFloat {
        textWidth + gap
    }

    private var staticLabel: some View {
        Text(verbatim: text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The full, unconstrained string measured off to the side: `fixedSize`
    /// overrides the proposed width with the ideal one, and a background sits
    /// outside the layout so overflowing it costs nothing.
    private var sizingProbe: some View {
        Text(verbatim: text)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .hidden()
            .background { MarqueeWidthReader { textWidth = $0 } }
            .allowsHitTesting(false)
    }

    /// The width the label was actually granted.
    private var containerProbe: some View {
        MarqueeWidthReader { containerWidth = $0 }
    }

    /// Identity is keyed on the text and the distance, so a new track — or a
    /// resize — rebuilds the subtree with `offset` back at zero and restarts the
    /// cycle cleanly instead of repeating a partial, mid-flight range forever.
    @ViewBuilder
    private var scrollingTrack: some View {
        if isAnimating {
            MarqueeTrack(text: text, font: font, color: color, gap: gap, distance: cycleDistance)
                .id(MarqueeTrackIdentity(text: text, distance: cycleDistance))
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

/// Identity of one scroll cycle: a different string, or a different travel
/// distance, is a different track.
private struct MarqueeTrackIdentity: Hashable {
    let text: String
    let distance: CGFloat
}

/// Two spaced copies of the text sliding left by exactly one cycle.
///
/// At `-distance` the second copy sits precisely where the first started, so
/// `repeatForever` loops with no visible seam. The animation is committed ONCE on
/// appear; every later frame is interpolated by the render server.
private struct MarqueeTrack: View {
    let text: String
    let font: Font
    let color: Color
    let gap: CGFloat
    let distance: CGFloat

    @State private var offset: CGFloat = 0

    var body: some View {
        HStack(spacing: gap) {
            textCopy
            textCopy
        }
        .fixedSize()
        .offset(x: offset)
        .onAppear(perform: startScrolling)
    }

    private var textCopy: some View {
        Text(verbatim: text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func startScrolling() {
        guard distance > 0 else { return }
        withAnimation(
            .linear(duration: MarqueeLayout.scrollDuration(distance: distance))
                .repeatForever(autoreverses: false)
        ) {
            offset = -distance
        }
    }
}

/// Reports the width of whatever it is placed behind, on appear and on every
/// change. Deliberately not `onPreferenceChange`: that hands the value back in a
/// `@Sendable` closure, which cannot touch `@State` under Swift 6 strict
/// concurrency. `onAppear` / `onChange` are delivered on the main actor, outside
/// the update pass.
private struct MarqueeWidthReader: View {
    let onWidthChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onWidthChange(proxy.size.width) }
                .onChange(of: proxy.size.width) { _, newValue in onWidthChange(newValue) }
        }
        .allowsHitTesting(false)
    }
}

private extension View {
    /// Clips the scrolling copies to the label's bounds — applied ONLY while the
    /// marquee runs, so the static path keeps a plain `Text`'s render tree.
    @ViewBuilder
    func marqueeClipped(_ isEnabled: Bool) -> some View {
        if isEnabled {
            clipped()
        } else {
            self
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        MarqueeText(
            text: "A Ridiculously Long Song Title That Cannot Possibly Fit",
            font: .headline,
            color: .primary,
            isActive: true
        )
        MarqueeText(text: "Short Title", font: .headline, color: .primary, isActive: true)
        MarqueeText(
            text: "A Ridiculously Long Song Title That Cannot Possibly Fit",
            font: .headline,
            color: .secondary,
            isActive: false
        )
    }
    .designTokens(.standard)
    .frame(width: 220)
    .padding()
}
