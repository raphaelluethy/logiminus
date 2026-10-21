import AppKit
import QuartzCore

/// A panel that can never become key or main, so showing it never steals focus
/// from the presentation app (the bug Options+ has).
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class OverlayView: NSView {
    private let dim = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let dot = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.cgColor
        ring.fillColor = nil
        ring.strokeColor = NSColor(white: 1, alpha: 0.18).cgColor
        ring.lineWidth = 2
        dot.backgroundColor = NSColor(red: 1, green: 0.12, blue: 0.1, alpha: 0.95).cgColor
        dot.borderColor = NSColor(white: 1, alpha: 0.85).cgColor
        dot.borderWidth = 1.5
        dot.shadowColor = NSColor.red.cgColor
        dot.shadowOpacity = 0.9
        dot.shadowRadius = 10
        dot.shadowOffset = .zero
        for l in [dim, ring, dot] { l.actions = ["position": NSNull(), "path": NSNull(), "bounds": NSNull(), "hidden": NSNull()]; layer!.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func render(effect: Effect, at p: CGPoint, settings: Settings) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.isHidden = effect != .spotlight
        ring.isHidden = effect != .spotlight
        dot.isHidden = effect != .pointer
        switch effect {
        case .spotlight:
            let r = bounds.height * settings.spotlightSize
            let hole = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addEllipse(in: hole)
            dim.frame = bounds
            dim.path = path
            dim.opacity = Float(settings.dimOpacity)
            ring.frame = bounds
            ring.path = CGPath(ellipseIn: hole, transform: nil)
        case .pointer:
            let s = settings.pointerSize
            dot.bounds = CGRect(x: 0, y: 0, width: s, height: s)
            dot.cornerRadius = s / 2
            dot.position = p
        case .none:
            break
        }
        CATransaction.commit()
    }
}

final class Overlay {
    /// Above full-screen slideshows.
    static let level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
    private struct Entry { let panel: NSPanel; let view: OverlayView; let screen: NSScreen }
    private var entries: [Entry] = []
    private var active: Entry?
    private(set) var effect: Effect = .none
    private(set) var position: CGPoint = .zero   // drawn (smoothed), global Cocoa coordinates
    private var target: CGPoint = .zero          // where the raw motion puts it
    private var smoother = PointSmoother(level: .off)
    private var settleTimer: Timer?
    private let settings = Settings.shared

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        rebuild()
    }

    private func rebuild() {
        let wasEffect = effect
        entries.forEach { $0.panel.orderOut(nil) }
        entries = NSScreen.screens.map { screen in
            let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.level = Overlay.level
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.ignoresMouseEvents = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            return Entry(panel: panel, view: view, screen: screen)
        }
        active = nil
        position = clamp(position)   // the old spot may no longer be on any display
        target = clamp(target)
        smoother.reset()
        if wasEffect != .none { show(wasEffect, at: position) }
    }

    /// The screen the highlight is currently on.
    var screen: NSScreen? { active?.screen }

    func show(_ effect: Effect, at p: CGPoint? = nil) {
        if let p {
            position = p
            target = p
            smoother = PointSmoother(level: settings.smoothing)
        }
        self.effect = effect
        if effect == .none { hide(); return }
        update()
    }

    /// Moves by device deltas (y grows downward on the device).
    func move(dx: Double, dy: Double) {
        guard effect != .none else { return }
        target = clamp(CGPoint(x: target.x + dx, y: target.y - dy))
        step()
        scheduleSettle()
    }

    private func step() {
        position = clamp(smoother.smooth(target, at: CACurrentMediaTime()))
        update()
    }

    /// When motion events stop, keep filtering at display rate until the drawn
    /// position has caught up with the target (otherwise it would rest short of it).
    private func scheduleSettle() {
        settleTimer?.invalidate()
        settleTimer = Timer.common(after: 0.03) { [weak self] _ in
            self?.settleTimer = Timer.common(after: 1.0 / 60, repeating: true) { t in
                guard let self, self.effect != .none,
                      hypot(self.position.x - self.target.x, self.position.y - self.target.y) > 0.5 else {
                    t.invalidate()
                    return
                }
                self.step()
            }
        }
    }

    func hide() {
        settleTimer?.invalidate()
        effect = .none
        active?.panel.orderOut(nil)
        active = nil
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        if entries.contains(where: { NSPointInRect(p, $0.screen.frame) }) { return p }
        // Outside every screen: clamp into the nearest one.
        var best = p, bestDist = Double.infinity
        for e in entries {
            let f = e.screen.frame
            let q = CGPoint(x: min(max(p.x, f.minX), f.maxX - 1), y: min(max(p.y, f.minY), f.maxY - 1))
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestDist { bestDist = d; best = q }
        }
        return best
    }

    private func update() {
        guard let e = entries.first(where: { NSPointInRect(position, $0.screen.frame) }) ?? entries.first else { return }
        if active?.panel !== e.panel {
            active?.panel.orderOut(nil)
            active = e
        }
        let f = e.screen.frame
        e.view.render(effect: effect, at: CGPoint(x: position.x - f.minX, y: position.y - f.minY), settings: settings)
        if !e.panel.isVisible { e.panel.orderFrontRegardless() }
    }
}
