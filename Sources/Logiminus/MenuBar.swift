import AppKit

final class MenuBar: NSObject, NSMenuDelegate {
    private unowned let agent: Agent
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var settings: Settings { agent.settings }

    init(agent: Agent) {
        self.agent = agent
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    func refresh() {
        guard let button = item.button else { return }
        button.image = Self.icon(enabled: agent.enabled)
        button.appearsDisabled = !agent.controller.status.connected
        if let r = agent.timer.remaining {
            button.title = " " + Self.format(r)
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    /// Template icon matching the app icon: a pool of light around a laser dot.
    private static func icon(enabled: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let c = NSPoint(x: r.midX, y: r.midY)
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 1.5
            if enabled {
                NSColor.black.withAlphaComponent(0.35).setFill()
                ring.fill()
                NSColor.black.setStroke()
                ring.stroke()
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)).fill()
            } else {
                NSColor.black.setStroke()
                ring.stroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: r.minX + 3.5, y: r.minY + 3.5))
                slash.line(to: NSPoint(x: r.maxX - 3.5, y: r.maxY - 3.5))
                slash.lineWidth = 1.5
                slash.stroke()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = enabled ? "Logiminus (enabled)" : "Logiminus (disabled)"
        return img
    }

    private static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        agent.controller.refreshBattery()
        menu.removeAllItems()
        let st = agent.controller.status

        var line = st.connected ? "\(st.name) — connected via \(st.receiver)" : "Spotlight not connected"
        if st.connected, let b = st.battery { line += " · \(b)%\(st.charging ? " ⚡︎" : "")" }
        menu.addItem(label(line))
        if st.needsInputMonitoring {
            menu.addItem(action("⚠︎ Grant Input Monitoring (needed for Bluetooth)…", #selector(grantInputMonitoring)))
        }
        if !Keys.accessibilityTrusted {
            menu.addItem(action("⚠︎ Grant Accessibility permission…", #selector(grantAccessibility)))
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.logi.optionsplus.agent").isEmpty == false
            || NSWorkspace.shared.runningApplications.contains(where: { $0.executableURL?.lastPathComponent == "logioptionsplus_agent" }) {
            menu.addItem(label("⚠︎ Logi Options+ is running and will conflict"))
        }
        menu.addItem(.separator())

        menu.addItem(action("Enabled", #selector(toggleEnabled), key: "e", checked: agent.enabled))
        menu.addItem(.separator())

        menu.addItem(submenu("Light press", Effect.allCases.map { e in
            action(e.title, #selector(setLight(_:)), checked: settings.lightEffect == e, rep: e.rawValue)
        }))
        menu.addItem(submenu("Hard press", Effect.allCases.map { e in
            action(e.title, #selector(setHard(_:)), checked: settings.hardEffect == e, rep: e.rawValue)
        }))
        var start = [
            action("Automatic (presentation screen)", #selector(setStartScreen(_:)), checked: settings.startScreen == ScreenPicker.auto, rep: ScreenPicker.auto),
            action("Screen with mouse pointer", #selector(setStartScreen(_:)), checked: settings.startScreen == ScreenPicker.mouse, rep: ScreenPicker.mouse),
            NSMenuItem.separator(),
        ]
        let names = NSScreen.screens.map(\.localizedName)
        start += NSScreen.screens.enumerated().map { i, s in
            let id = s.uuid ?? s.localizedName
            // Tell identical monitors apart.
            let title = names.filter { $0 == s.localizedName }.count > 1 ? "\(s.localizedName) (\(i + 1))" : s.localizedName
            return action(title, #selector(setStartScreen(_:)), checked: settings.startScreen == id, rep: id)
        }
        menu.addItem(submenu("Start on", start))
        menu.addItem(submenu("Top button tap", TapAction.allCases.map { a in
            action(a.title, #selector(setTapAction(_:)), checked: settings.tapAction == a, rep: a.rawValue)
        }))
        menu.addItem(submenu("Pointer smoothing", Smoothing.allCases.map { l in
            action(l.title, #selector(setSmoothing(_:)), checked: settings.smoothing == l, rep: l.rawValue)
        }))
        menu.addItem(submenu("Pointer speed", [("Slow", 0.5), ("Normal", 1.0), ("Fast", 1.6), ("Very fast", 2.5)].map { t, v in
            action(t, #selector(setSpeed(_:)), checked: abs(settings.pointerSpeed - v) < 0.01, rep: v)
        }))
        menu.addItem(submenu("Pointer size", [("Tiny", 7.0), ("Small", 11.0), ("Medium", 16.0), ("Large", 22.0)].map { t, v in
            action(t, #selector(setPointerSize(_:)), checked: abs(settings.pointerSize - v) < 0.01, rep: v)
        }))
        menu.addItem(submenu("Mouse cursor", [label("Needed to see the pointer when sharing a single window"), .separator()]
            + CursorFollow.allCases.map { c in
                action(c.title, #selector(setCursorFollow(_:)), checked: settings.cursorFollow == c, rep: c.rawValue)
            }))
        menu.addItem(submenu("Spotlight size", [("Small", 0.12), ("Medium", 0.18), ("Large", 0.26)].map { t, v in
            action(t, #selector(setSize(_:)), checked: abs(settings.spotlightSize - v) < 0.01, rep: v)
        }))
        menu.addItem(submenu("Spotlight dimming", [("Light", 0.5), ("Medium", 0.75), ("Dark", 0.9)].map { t, v in
            action(t, #selector(setDim(_:)), checked: abs(settings.dimOpacity - v) < 0.01, rep: v)
        }))

        var haptics = [action("Haptic feedback", #selector(toggleHaptics), checked: settings.hapticsEnabled), NSMenuItem.separator()]
        haptics += [("Low", 15), ("Medium", 35), ("High", 60)].map { t, v in
            action(t, #selector(setHapticLevel(_:)), checked: settings.hapticLevel == v, rep: v)
        }
        haptics += [.separator(), action("Test vibration", #selector(testHaptic))]
        menu.addItem(submenu("Haptics", haptics))

        var timer: [NSMenuItem] = []
        if let r = agent.timer.remaining {
            timer.append(label("Remaining \(Self.format(r))"))
            timer.append(action("Stop timer", #selector(stopTimer)))
        } else {
            timer.append(action("Start timer now", #selector(startTimer), enabled: settings.timerMinutes > 0))
        }
        timer.append(.separator())
        timer += [0, 5, 10, 15, 20, 30, 45, 60].map { m in
            action(m == 0 ? "Off" : "\(m) minutes", #selector(setTimer(_:)), checked: settings.timerMinutes == m, rep: m)
        }
        timer.append(.separator())
        timer.append(action("Start with presentation", #selector(toggleTimerWithPresentation), checked: settings.startTimerWithPresentation))
        menu.addItem(submenu("Presentation timer", timer))

        menu.addItem(.separator())
        menu.addItem(action("Open at Login", #selector(toggleLogin), checked: LoginItem.isEnabled))
        menu.addItem(action("Quit Logiminus", #selector(quit), key: "q"))
    }

    // MARK: builders

    private func label(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, key: String = "", checked: Bool = false,
                        rep: Any? = nil, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        i.state = checked ? .on : .off
        i.representedObject = rep
        i.isEnabled = enabled
        return i
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu()
        m.autoenablesItems = false
        items.forEach(m.addItem)
        i.submenu = m
        return i
    }

    // MARK: actions

    @objc private func toggleEnabled() { agent.setEnabled(!agent.enabled) }
    @objc private func grantAccessibility() {
        Keys.promptForAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func grantInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc private func setLight(_ i: NSMenuItem) { settings.lightEffect = Effect(rawValue: i.representedObject as! String)! }
    @objc private func setHard(_ i: NSMenuItem) { settings.hardEffect = Effect(rawValue: i.representedObject as! String)! }
    @objc private func setSmoothing(_ i: NSMenuItem) { settings.smoothing = Smoothing(rawValue: i.representedObject as! Int)! }
    @objc private func setCursorFollow(_ i: NSMenuItem) { settings.cursorFollow = CursorFollow(rawValue: i.representedObject as! String)! }
    @objc private func setTapAction(_ i: NSMenuItem) { settings.tapAction = TapAction(rawValue: i.representedObject as! String)! }
    @objc private func setStartScreen(_ i: NSMenuItem) { settings.startScreen = i.representedObject as! String }
    @objc private func setSpeed(_ i: NSMenuItem) { settings.pointerSpeed = i.representedObject as! Double }
    @objc private func setPointerSize(_ i: NSMenuItem) { settings.pointerSize = i.representedObject as! Double }
    @objc private func setSize(_ i: NSMenuItem) { settings.spotlightSize = i.representedObject as! Double }
    @objc private func setDim(_ i: NSMenuItem) { settings.dimOpacity = i.representedObject as! Double }
    @objc private func toggleHaptics() {
        settings.hapticsEnabled.toggle()
        agent.controller.setHaptics(enabled: settings.hapticsEnabled, level: settings.hapticLevel)
    }
    @objc private func setHapticLevel(_ i: NSMenuItem) {
        settings.hapticLevel = i.representedObject as! Int
        agent.controller.setHaptics(enabled: settings.hapticsEnabled, level: settings.hapticLevel)
        agent.controller.playHaptic(Haptic.timerWarning)
    }
    @objc private func testHaptic() { agent.controller.playHaptic(Haptic.manual) }
    @objc private func startTimer() { agent.timer.start(minutes: settings.timerMinutes); refresh() }
    @objc private func stopTimer() { agent.timer.stop(); refresh() }
    @objc private func setTimer(_ i: NSMenuItem) { settings.timerMinutes = i.representedObject as! Int }
    @objc private func toggleTimerWithPresentation() { settings.startTimerWithPresentation.toggle() }
    @objc private func toggleLogin() {
        if let err = LoginItem.set(!LoginItem.isEnabled) { Log.info("login item: \(err)") }
    }
    @objc private func quit() { agent.quit() }
}
