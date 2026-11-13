// Locks the pure scroll/no-scroll decision behind MarqueeText (bugfix-batch-10 todo 6).
//
// `MarqueeLayout` is deliberately a SwiftUI-free namespace — `View` is a
// `@MainActor` protocol, so a rule living on the view would trap when a
// nonisolated test called it. Asserting the truth table here locks the behaviour
// every marquee call site depends on: overflow scrolls, and reduce-motion or an
// inactive caller never does (the idle-CPU guarantee).
import CoreGraphics
import DesignSystem
import Testing

@Suite("MarqueeLayoutTests")
struct MarqueeLayoutTests {
    @Test("Text wider than its container scrolls while active")
    func overflowingTextScrolls() {
        #expect(
            MarqueeLayout.shouldAnimate(
                textWidth: 300,
                containerWidth: 200,
                reduceMotion: false,
                isActive: true
            ) == true
        )
    }

    @Test("Text that fits never scrolls")
    func fittingTextStaysStatic() {
        #expect(
            MarqueeLayout.shouldAnimate(
                textWidth: 150,
                containerWidth: 200,
                reduceMotion: false,
                isActive: true
            ) == false
        )
    }

    @Test("Reduce motion forces a static label even when the text overflows")
    func reduceMotionStaysStatic() {
        #expect(
            MarqueeLayout.shouldAnimate(
                textWidth: 300,
                containerWidth: 200,
                reduceMotion: true,
                isActive: true
            ) == false
        )
    }

    @Test("An inactive caller never scrolls — idle CPU stays at zero")
    func inactiveStaysStatic() {
        #expect(
            MarqueeLayout.shouldAnimate(
                textWidth: 300,
                containerWidth: 200,
                reduceMotion: false,
                isActive: false
            ) == false
        )
    }
}
