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
    /// Above full-screen slideshows; the blackout sits one level below the highlight.
    static let level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
    private struct Entry { let panel: NSPanel; let view: OverlayView; let screen: NSScreen }
    private var entries: [Entry] = []
    private var active: Entry?
    private(set) var effect: Effect = .none
    private(set) var position: CGPoint = .zero   // global Cocoa coordinates
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
        if wasEffect != .none { show(wasEffect, at: position) }
    }

    /// The screen the highlight is currently on.
    var screen: NSScreen? { active?.screen }

    func show(_ effect: Effect, at p: CGPoint? = nil) {
        if let p { position = p }
        self.effect = effect
        if effect == .none { hide(); return }
        update()
    }

    /// Moves by device deltas (y grows downward on the device).
    func move(dx: Double, dy: Double) {
        guard effect != .none else { return }
        position = clamp(CGPoint(x: position.x + dx, y: position.y - dy))
        update()
    }

    func hide() {
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

/// Covers one display in black ("blank screen" during a presentation).
final class Blackout {
    private var panel: NSPanel?
    var isActive: Bool { panel != nil }

    func show(on screen: NSScreen) {
        hide()
        let p = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Overlay.level.rawValue - 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.isOpaque = true
        p.backgroundColor = .black
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.setFrame(screen.frame, display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        panel = p
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 },
                                             completionHandler: { p.orderOut(nil) })
    }
}
