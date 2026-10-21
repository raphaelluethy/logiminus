import AppKit
import Carbon.HIToolbox

/// The menu bar agent: owns the device controller and turns button/motion
/// events into overlay effects and keystrokes.
final class Agent: NSObject {
    let settings = Settings.shared
    let controller: SpotlightController
    private var overlay: Overlay!
    private let screens = ScreenPicker()
    private var menu: MenuBar!
    private var server: IPC.Server!
    let timer = PresentationTimer()

    private var pressed = Set<UInt16>()
    private var repeatTimer: Timer?

    override init() {
        controller = SpotlightController(diverted: Settings.shared.enabled)
        super.init()
    }

    func start() {
        // Claim the control socket first: a second instance must not touch the device.
        server = IPC.Server { [weak self] in self?.command($0) ?? "error" }
        do {
            try server.start()
        } catch IPC.ServerError.alreadyRunning {
            Log.info("another Logiminus agent is already running")
            FileHandle.standardError.write(Data("logiminus: another agent is already running\n".utf8))
            exit(0)
        } catch {
            Log.info("control socket: \(error)")
        }

        overlay = Overlay()
        menu = MenuBar(agent: self)
        controller.onButtons = { [weak self] in self?.buttons($0) }
        controller.onMotion = { [weak self] in self?.motion($0, $1) }
        controller.onStatus = { [weak self] _ in self?.menu.refresh() }
        timer.onAlert = { [weak self] final in
            guard let self, self.settings.hapticsEnabled else { return }
            self.controller.playHaptic(final ? Haptic.timerEnd : Haptic.timerWarning)
        }
        timer.onTick = { [weak self] in self?.menu.refresh() }
        controller.start()

        if !Keys.accessibilityTrusted { Keys.promptForAccessibility() }

        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.quit() }
            src.resume()
            signalSources.append(src)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.shutdown()
        }
    }
    private var signalSources: [DispatchSourceSignal] = []

    // MARK: enable / disable

    var enabled: Bool { settings.enabled }

    func setEnabled(_ on: Bool) {
        settings.enabled = on
        if !on { releaseAll() }
        controller.setDiverted(on)
        menu.refresh()
    }

    private var didShutdown = false
    private func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        server.stop()
        controller.restoreNative()
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    /// IPC command handler (main queue).
    func command(_ line: String) -> String {
        let parts = line.split(separator: " ").map(String.init)
        switch parts.first ?? "" {
        case "enable": setEnabled(true); return statusLine()
        case "disable": setEnabled(false); return statusLine()
        case "toggle": setEnabled(!enabled); return statusLine()
        case "status": return statusLine()
        case "haptic":
            guard parts.count > 1, let id = UInt8(parts[1]) else { return "error: usage: haptic <0-255>" }
            controller.playHaptic(id); return "ok"
        case "timer":
            switch parts.count > 1 ? parts[1] : "" {
            case "start":
                var minutes = settings.timerMinutes
                if parts.count > 2 {
                    guard let m = Int(parts[2]), PresentationTimer.validMinutes.contains(m) else {
                        return "error: minutes must be 1–\(PresentationTimer.validMinutes.upperBound)"
                    }
                    minutes = m
                }
                guard minutes > 0 else { return "error: no timer duration set" }
                timer.start(minutes: minutes); menu.refresh(); return "timer started (\(minutes) min)"
            case "stop": timer.stop(); menu.refresh(); return "timer stopped"
            default: return "error: usage: timer start [minutes] | stop"
            }
        case "login":
            switch parts.count > 1 ? parts[1] : "" {
            case "on", "off":
                if let err = LoginItem.set(parts[1] == "on") { return "error: \(err)" }
                menu.refresh()
                return "open at login: \(LoginItem.statusText)"
            case "", "status": return "open at login: \(LoginItem.statusText)"
            default: return "error: usage: login on | off | status"
            }
        case "quit":
            DispatchQueue.main.async { self.quit() }
            return "bye"
        default: return "error: unknown command \(line)"
        }
    }

    func statusLine() -> String {
        let s = controller.status
        var out = enabled ? "enabled" : "disabled"
        if s.connected {
            out += " · \(s.name) connected via \(s.receiver)"
            if let b = s.battery { out += " · battery \(b)%" }
        } else {
            out += " · device not connected"
        }
        if !Keys.accessibilityTrusted { out += " · ⚠︎ Accessibility permission missing" }
        if s.needsInputMonitoring { out += " · ⚠︎ Input Monitoring permission needed for Bluetooth" }
        return out
    }

    // MARK: events

    private func releaseAll() {
        buttons([])
    }

    private func buttons(_ now: Set<UInt16>) {
        guard enabled || now.isEmpty else { return }
        let down = now.subtracting(pressed), up = pressed.subtracting(now)
        pressed = now
        for cid in down { buttonDown(cid) }
        for cid in up { buttonUp(cid) }
        updateHighlight()
    }

    private func buttonDown(_ cid: UInt16) {
        switch cid {
        case CID.next, CID.nextHold:
            Keys.tap(kVK_RightArrow)
        case CID.back:
            Keys.tap(kVK_LeftArrow)
        case CID.topTap where settings.tapAction == .click:
            Keys.click()
        case CID.backHold where screens.presentationScreen() != nil:
            // During a presentation: let the app black the screen (⇧B in Keynote, PowerPoint, Google Slides).
            Keys.tap(kVK_ANSI_B, .maskShift)
        case CID.backHold:
            // Fast backwards: keep stepping while held (Options+: 200 ms then every 75 ms).
            Keys.tap(kVK_LeftArrow)
            repeatTimer?.invalidate()
            repeatTimer = Timer.common(after: 0.2) { [weak self] _ in
                self?.repeatTimer = Timer.common(after: 0.075, repeating: true) { _ in Keys.tap(kVK_LeftArrow) }
            }
        case CID.startStop:
            if PresentationControl.toggle(presenting: screens.presentationScreen() != nil) {
                if settings.startTimerWithPresentation && settings.timerMinutes > 0 { timer.start(minutes: settings.timerMinutes) }
            } else {
                timer.stop()
            }
            menu.refresh()
        case CID.haptic:
            controller.playHaptic(Haptic.manual)
        default:
            break
        }
    }

    private func buttonUp(_ cid: UInt16) {
        if cid == CID.backHold {
            repeatTimer?.invalidate()
            repeatTimer = nil
        }
    }

    private func updateHighlight() {
        let effect: Effect
        if pressed.contains(CID.topHard) {
            effect = settings.hardEffect
        } else if pressed.contains(CID.topLight) {
            effect = settings.lightEffect
        } else {
            effect = .none
        }
        guard effect != overlay.effect else { return }
        if effect == .none {
            screens.remember(overlay.screen)
            overlay.hide()
        } else if overlay.effect == .none {
            let f = screens.startScreen(preference: settings.startScreen)?.frame ?? .zero
            overlay.show(effect, at: CGPoint(x: f.midX, y: f.midY))
        } else {
            overlay.show(effect)
        }
    }

    private func motion(_ dx: Int, _ dy: Int) {
        guard enabled, overlay.effect != .none else { return }
        overlay.move(dx: Double(dx), dy: Double(dy), speed: settings.pointerSpeed)
    }
}

enum Haptic {
    static let manual: UInt8 = 17         // "belly_breathing" in Options+
    static let timerWarning: UInt8 = 1
    static let timerEnd: UInt8 = 3
}

/// Presentation timer with haptic alerts 5 min and 1 min before the end, and at the end.
final class PresentationTimer {
    var onAlert: ((Bool) -> Void)?
    var onTick: (() -> Void)?
    private(set) var endDate: Date?
    private var alerts: [(Date, Bool)] = []
    private var timer: Timer?

    var remaining: TimeInterval? { endDate.map { max(0, $0.timeIntervalSinceNow) } }

    static let validMinutes = 1...600

    func start(minutes: Int) {
        let minutes = min(max(minutes, Self.validMinutes.lowerBound), Self.validMinutes.upperBound)
        let end = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        endDate = end
        alerts = [(end, true)]
        for warn in [5, 1] where minutes > warn {
            alerts.append((end.addingTimeInterval(TimeInterval(-warn * 60)), false))
        }
        timer?.invalidate()
        timer = Timer.common(after: 1, repeating: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        endDate = nil
        alerts = []
        onTick?()
    }

    private func tick() {
        let now = Date()
        for (i, a) in alerts.enumerated().reversed() where a.0 <= now {
            alerts.remove(at: i)
            onAlert?(a.1)
        }
        if alerts.isEmpty { stop() } else { onTick?() }
    }
}

extension Timer {
    /// A main-run-loop timer in the common modes, so it keeps firing while a menu is open.
    static func common(after interval: TimeInterval, repeating: Bool = false, _ block: @escaping (Timer) -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: repeating, block: block)
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}
