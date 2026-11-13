// InlineSpectrumNSView — the compact spectrum renderer as a plain AppKit view.
//
// AppKit on purpose, NOT SwiftUI: any SwiftUI-driven redraw (TimelineView tick)
// marks its NSHostingView as needing layout AND constraint updates, which
// re-enters the window's constraint pass and recomputes the window content-size
// extrema — a full window sizeThatFits, 30 times per second, ~20% of a core
// while playing (profiled; it made every chrome animation stutter during
// playback). A plain NSView redraw via `needsDisplay` touches neither layout
// nor constraints. Consumer-side pull only — never touches the audio-thread
// spectrum producer.
import AppKit
import DesignSystem
import QuartzCore
import SwiftUI
import ViewModels
import Visualizer

final class InlineSpectrumNSView: NSView {
    private static let barCount = 24

    private var bars = [CGFloat](repeating: 2, count: InlineSpectrumNSView.barCount)
    private var timer: Timer?

    /// This view's OWN envelope, stepped off the wall clock so its 30 fps pull
    /// decays at the same rate per second as the 60 fps Metal visualizer. Each
    /// on-screen consumer keeps a private instance — sharing one would couple two
    /// independent redraw cadences.
    private var ballistics = SpectrumBallistics()
    private var lastTickTime: CFTimeInterval = 0

    weak var visualizer: VisualizerViewModel?
    var onTap: (() -> Void)?

    var currentMode: VisualizerMode = .bars {
        didSet { if oldValue != currentMode { needsDisplay = true } }
    }

    var minimumInterval = 1.0 / 30.0 {
        didSet { if isActive, oldValue != minimumInterval { restartTimer() } }
    }

    var isActive = false {
        didSet { if oldValue != isActive { restartTimer() } }
    }

    private let neonPink = NSColor(SpectrumColors.neonPink.color).cgColor
    private let neonCyan = NSColor(SpectrumColors.neonCyan.color).cgColor
    private let neonPurple = NSColor(SpectrumColors.neonPurple.color).cgColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.drawsAsynchronously = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            timer?.invalidate()
            timer = nil
        } else if isActive, timer == nil {
            restartTimer()
        }
    }

    override func mouseDown(with _: NSEvent) {
        onTap?()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard isActive else {
            bars = [CGFloat](repeating: 2, count: Self.barCount)
            ballistics.reset()
            lastTickTime = 0
            needsDisplay = true
            return
        }
        let newTimer = Timer(
            timeInterval: minimumInterval,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        newTimer.tolerance = minimumInterval * 0.25
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    @objc private func tick() {
        guard let visualizer else { return }
        let now = CACurrentMediaTime()
        let elapsed = lastTickTime > 0 ? now - lastTickTime : minimumInterval
        lastTickTime = now
        let spectrum = ballistics.step(new: visualizer.sample(), elapsed: elapsed)
        if spectrum.isEmpty {
            bars = [CGFloat](repeating: 2, count: Self.barCount)
        } else {
            let step = max(1, spectrum.count / Self.barCount)
            bars = (0 ..< Self.barCount).map { index in
                let sourceIndex = min(index * step, spectrum.count - 1)
                return CGFloat(spectrum[sourceIndex]) * 34
            }
        }
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        switch currentMode {
        case .bars: drawBars(context)
        case .oscilloscope: drawOscilloscope(context)
        case .particles: drawParticles(context)
        case .aurora: drawAurora(context)
        }
    }
}

// MARK: - Mode drawing

private extension InlineSpectrumNSView {
    func gradient(_ colors: [CGColor]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)
    }

    func drawBars(_ context: CGContext) {
        guard let fill = gradient([neonPink, neonPurple, neonCyan]) else { return }
        let spacing: CGFloat = 2
        let slot = bounds.width / CGFloat(bars.count)
        let barWidth = max(1, slot - spacing)
        let bottom = bounds.height
        for (index, bar) in bars.enumerated() {
            let height = min(max(2, bar), bottom)
            let rect = CGRect(
                x: CGFloat(index) * slot + spacing / 2,
                y: bottom - height,
                width: barWidth,
                height: height
            )
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.clip()
            context.drawLinearGradient(
                fill,
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.minY),
                options: []
            )
            context.restoreGState()
        }
    }

    func drawOscilloscope(_ context: CGContext) {
        guard bars.count > 1, let stroke = gradient([neonPink, neonCyan]) else { return }
        let midY = bounds.height * 0.5
        let segmentWidth = bounds.width / CGFloat(bars.count - 1)
        let path = CGMutablePath()
        for (index, sample) in bars.enumerated() {
            let posX = CGFloat(index) * segmentWidth
            let energy = min(sample / 34.0, 1.0)
            let posY = midY - energy * midY * 0.9
            if index == 0 {
                path.move(to: CGPoint(x: posX, y: posY))
            } else {
                path.addLine(to: CGPoint(x: posX, y: posY))
            }
        }
        context.saveGState()
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(
            stroke,
            start: CGPoint(x: 0, y: midY),
            end: CGPoint(x: bounds.width, y: midY),
            options: []
        )
        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(neonPurple.copy(alpha: 0.3) ?? neonPurple)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: 0, y: midY))
        context.addLine(to: CGPoint(x: bounds.width, y: midY))
        context.strokePath()
        context.restoreGState()
    }

    func drawParticles(_ context: CGContext) {
        let bottom = bounds.height
        for (index, bar) in bars.enumerated() {
            let fraction = CGFloat(index) / CGFloat(max(bars.count - 1, 1))
            let posX = fraction * bounds.width
            let energy = min(bar / 34.0, 1.0)
            let posY = bottom - energy * bottom * 0.9
            let dotSize = 2 + energy * 5
            let color = fraction < 0.33 ? neonPink : (fraction < 0.66 ? neonPurple : neonCyan)
            let rect = CGRect(x: posX - dotSize / 2, y: posY - dotSize / 2, width: dotSize, height: dotSize)
            context.setFillColor(color)
            context.fillEllipse(in: rect)

            guard energy > 0.2 else { continue }
            let trailCount = max(1, Int(energy * 3))
            for trail in 1 ... trailCount {
                let trailY = posY + CGFloat(trail) * dotSize * 0.8
                guard trailY < bottom else { continue }
                let trailSize = dotSize * (1.0 - CGFloat(trail) * 0.3)
                let trailRect = CGRect(
                    x: posX - trailSize / 2,
                    y: trailY - trailSize / 2,
                    width: trailSize,
                    height: trailSize
                )
                context.setFillColor(color.copy(alpha: 0.3 / CGFloat(trail)) ?? color)
                context.fillEllipse(in: trailRect)
            }
        }
    }

    func drawAurora(_ context: CGContext) {
        guard bars.count > 1 else { return }
        let fillColors = [
            neonPink.copy(alpha: 0.8) ?? neonPink,
            neonPurple.copy(alpha: 0.6) ?? neonPurple,
            neonCyan.copy(alpha: 0.8) ?? neonCyan,
        ]
        guard let fill = gradient(fillColors) else { return }
        let bottom = bounds.height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: bottom))
        for (index, bar) in bars.enumerated() {
            let fraction = CGFloat(index) / CGFloat(bars.count - 1)
            let posX = fraction * bounds.width
            let energy = min(bar / 34.0, 1.0)
            let posY = bottom - energy * bottom * 0.9
            path.addLine(to: CGPoint(x: posX, y: posY))
        }
        path.addLine(to: CGPoint(x: bounds.width, y: bottom))
        path.closeSubpath()

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(
            fill,
            start: .zero,
            end: CGPoint(x: bounds.width, y: bottom),
            options: []
        )
        context.restoreGState()
    }
}
