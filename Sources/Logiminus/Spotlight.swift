import Foundation
import IOKit.hid

/// Control IDs of the Spotlight 2 (feature 0x1B04), as reported by the device.
enum CID {
    static let topTap: UInt16 = 0x0050        // top button, quick tap (natively a left click)
    static let topLight: UInt16 = 0x00D8      // top button, light press held
    static let topHard: UInt16 = 0x01A8       // top button, hard (force) press
    static let next: UInt16 = 0x00D9          // the device itself tells click and hold apart
    static let nextHold: UInt16 = 0x00DA
    static let back: UInt16 = 0x00DB
    static let backHold: UInt16 = 0x00DC
    static let startStop: UInt16 = 0x00FB
    static let haptic: UInt16 = 0x01B0

    /// Controls we divert, and whether we also want raw XY motion for them.
    static let diverted: [(cid: UInt16, rawXY: Bool)] = [
        (topLight, true), (topHard, true),
        (next, false), (nextHold, false), (back, false), (backHold, false),
        (startStop, false), (haptic, false), (topTap, false),
    ]
}

struct DeviceStatus {
    var connected = false
    var name = ""
    var receiver = ""   // "USB receiver" or "Bluetooth"
    var battery: Int?
    var charging = false
    var needsInputMonitoring = false
}

/// Finds the Spotlight on any attached receiver, keeps its configuration applied
/// across sleep/reconnect, and forwards button and motion events to the main queue.
final class SpotlightController {
    /// Called on the main queue with the set of currently pressed diverted controls.
    var onButtons: ((Set<UInt16>) -> Void)?
    /// Called on the main queue with raw motion deltas while the top button is held.
    var onMotion: ((Int, Int) -> Void)?
    /// Called on the main queue whenever `status` changes.
    var onStatus: ((DeviceStatus) -> Void)?

    private(set) var status = DeviceStatus()   // main queue
    private let hid = HIDManager()
    private let ctl = DispatchQueue(label: "logiminus.ctl", qos: .userInitiated)

    // ctl queue state
    private var device: HIDPPDevice?
    private var link = LinkTracker()   // is the attached device currently awake/connected
    private var transports: [HIDPPTransport] = []
    private var notSpotlight: Set<String> = []
    private var wantDiverted: Bool
    /// When false the controller only listens (debug monitor) and never writes configuration.
    private let manage: Bool

    // Routing info read from the HID thread.
    private struct Route { let location: Int; let index: UInt8; let reprog: UInt8; let wireless: UInt8?; let battery: UInt8? }
    private let routeLock = NSLock()
    private var route: Route?

    init(diverted: Bool, manage: Bool = true) {
        wantDiverted = diverted
        self.manage = manage
    }

    func start() {
        hid.onAdded = { [weak self] t in
            guard let self else { return }
            t.onReport = { [weak self, weak t] r in if let t { self?.report(r, from: t) } }
            ctl.async { self.transports.append(t); self.scan(t) }
        }
        hid.onRemoved = { [weak self] t in
            guard let self else { return }
            ctl.async {
                self.transports.removeAll { $0 === t }
                if self.device?.transport === t { self.detach() }
            }
        }
        hid.onPermissionNeeded = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.status.needsInputMonitoring = true
                self.onStatus?(self.status)
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
        }
        hid.onPermissionGranted = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.status.needsInputMonitoring = false
                self.onStatus?(self.status)
            }
        }
        hid.start()
        // While nothing is attached, rescan now and then (covers a remote that was asleep).
        let rescan = DispatchSource.makeTimerSource(queue: ctl)
        rescan.schedule(deadline: .now() + 10, repeating: 10)
        rescan.setEventHandler { [weak self] in
            guard let self, self.device == nil || !self.link.linked else { return }
            self.transports.forEach(self.scan)
        }
        rescan.resume()
        rescanTimer = rescan
    }
    private var rescanTimer: DispatchSourceTimer?

    // MARK: public API (any thread)

    func setDiverted(_ on: Bool, completion: (() -> Void)? = nil) {
        ctl.async {
            self.wantDiverted = on
            if let d = self.device { self.configure(d) }
            completion.map { DispatchQueue.main.async(execute: $0) }
        }
    }

    /// Synchronously restores native button behaviour (used on quit).
    func restoreNative() {
        ctl.sync {
            wantDiverted = false
            if let d = device { configure(d) }
        }
    }

    func playHaptic(_ waveform: UInt8) {
        ctl.async {
            guard let d = self.device else { return }
            do { _ = try d.call(Feature.haptics, 3, [waveform]) } catch { Log.info("haptic \(waveform): \(error)") }
        }
    }

    func setHaptics(enabled: Bool, level: Int) {
        ctl.async {
            guard let d = self.device else { return }
            self.applyHaptics(d, enabled: enabled, level: level)
        }
    }

    func refreshBattery() {
        ctl.async { if let d = self.device { self.readBattery(d) } }
    }

    /// Debug helper: raw request on the attached device.
    func raw(feature: UInt16, function: UInt8, params: [UInt8], completion: @escaping (String) -> Void) {
        ctl.async {
            guard let d = self.device else { return completion("error: not connected") }
            do { completion(hex(try d.call(feature, function, params))) } catch { completion("error: \(error)") }
        }
    }

    // MARK: discovery (ctl queue)

    private func key(_ t: HIDPPTransport, _ i: UInt8) -> String { "\(t.location)/\(i)" }

    private func scan(_ t: HIDPPTransport) {
        guard device == nil || !link.linked else { return }
        // Receivers multiplex up to 6 devices; 0xFF addresses a directly connected one.
        for i: UInt8 in t.isBluetooth ? [0xFF] : [1, 2, 3, 4, 5, 6] {
            if probe(t, index: i) { return }
        }
    }

    @discardableResult
    private func probe(_ t: HIDPPTransport, index: UInt8) -> Bool {
        guard device == nil || !link.linked, !notSpotlight.contains(key(t, index)) else { return false }
        let d = HIDPPDevice(transport: t, index: index)
        do {
            // A sleeping device answers "offline" (or not at all) until the ping wakes it up.
            var version: (UInt8, UInt8)?
            for attempt in 0..<3 {
                do { version = try d.ping(timeout: 0.6); break }
                catch let e as HIDPPError where e.isOffline && attempt < 2 { Thread.sleep(forTimeInterval: 0.4) }
            }
            let (major, _) = version!
            guard major >= 2 else { notSpotlight.insert(key(t, index)); return false }
            let name = try d.name()
            guard name.localizedCaseInsensitiveContains("spotlight"), d.hasFeature(Feature.reprogControls) else {
                Log.info(String(format: "ignoring %@ at %08x/%d", name, t.location, index))
                notSpotlight.insert(key(t, index))
                return false
            }
            attach(d, name: name)
            return true
        } catch {
            if case .hidpp10(let e) = error as? HIDPPError, e == 0x01 || e == 0x02 || e == 0x09 {
                // No device paired in this slot (or 0xFF addressed the receiver itself).
            } else {
                Log.debug(String(format: "probe %08x/%d: %@", t.location, index, "\(error)"))
            }
            return false
        }
    }

    private func attach(_ d: HIDPPDevice, name: String) {
        device = d
        originalLayers = [:]
        link.update(true)
        do {
            let reprog = try d.featureIndex(Feature.reprogControls)
            let wireless = try? d.featureIndex(Feature.wirelessStatus)
            let battery = try? d.featureIndex(Feature.unifiedBattery)
            routeLock.lock()
            route = Route(location: d.transport.location, index: d.index, reprog: reprog, wireless: wireless, battery: battery)
            routeLock.unlock()
        } catch {
            Log.info("attach failed: \(error)")
            device = nil
            return
        }
        Log.info(String(format: "found %@ on %@ (loc %08x, index %d)", name, d.transport.product, d.transport.location, d.index))
        let receiver = d.transport.kind
        DispatchQueue.main.async {
            self.status.connected = true
            self.status.name = name
            self.status.receiver = receiver
            self.onStatus?(self.status)
        }
        readBattery(d)
        guard manage else { return }
        configure(d)
        let s = Settings.shared
        applyHaptics(d, enabled: s.hapticsEnabled, level: s.hapticLevel)
    }

    private func detach() {
        device = nil
        link.update(false)
        routeLock.lock(); route = nil; routeLock.unlock()
        DispatchQueue.main.async {
            self.status.connected = false
            self.onStatus?(self.status)
            self.onButtons?([])
        }
    }

    /// Applies (or removes) button diversion.
    private func configure(_ d: HIDPPDevice) {
        guard manage else { return }
        for (cid, raw) in CID.diverted {
            var flags: UInt8 = wantDiverted ? 0x03 : 0x02          // divert + valid
            if raw { flags |= wantDiverted ? 0x30 : 0x20 }         // raw XY + valid
            let params = [UInt8(cid >> 8), UInt8(cid & 0xFF), flags, 0, 0]
            do {
                _ = try d.call(Feature.reprogControls, 3, params)
            } catch {
                Log.info(String(format: "setCidReporting 0x%04x: %@", cid, "\(error)"))
                if (error as? HIDPPError)?.isOffline == true { return }   // asleep; redone on reconnect
            }
        }
        Log.info("diversion \(wantDiverted ? "on" : "off")")
        configureForceLayers(d)
    }

    /// Original force-layer masks per button, restored when we hand the device back.
    private var originalLayers: [UInt8: UInt8] = [:]

    /// The hard press is a second force "layer" that is per host and off by default
    /// (Options+ only enabled it on the receiver connection). 0x19C0 fn5/fn6 get/set
    /// `[button, mask]`, bit0 = light, bit1 = hard.
    private func configureForceLayers(_ d: HIDPPDevice) {
        guard let count = try? d.call(Feature.forceSensing, 0).first else { return }
        for button in 0..<count {
            do {
                if originalLayers[button] == nil {
                    originalLayers[button] = try d.call(Feature.forceSensing, 5, [button]).first
                }
                let mask: UInt8 = wantDiverted ? 0x03 : originalLayers[button] ?? 0x01
                _ = try d.call(Feature.forceSensing, 6, [button, mask])
            } catch {
                Log.info("force layers \(button): \(error)")
            }
        }
    }

    private func readBattery(_ d: HIDPPDevice) {
        guard let r = try? d.call(Feature.unifiedBattery, 1) else { return }
        updateBattery(r)
    }

    private func updateBattery(_ r: [UInt8]) {
        // getStatus: [percent, level flags, charging status, external power]
        let pct = Int(r[0]), charging = r[2] == 1 || r[2] == 2
        DispatchQueue.main.async {
            self.status.battery = pct
            self.status.charging = charging
            self.onStatus?(self.status)
        }
    }

    private func applyHaptics(_ d: HIDPPDevice, enabled: Bool, level: Int) {
        do { _ = try d.call(Feature.haptics, 2, [enabled ? 1 : 0, UInt8(clamping: level)]) }
        catch { Log.info("haptic config: \(error)") }
    }

    // MARK: events (HID thread)

    private func report(_ r: [UInt8], from t: HIDPPTransport) {
        routeLock.lock(); let rt = route; routeLock.unlock()

        // Receiver: device connection notification.
        if r[2] == 0x41, r.count >= 5 {
            let index = r[1], linked = r[4] & 0x40 == 0
            Log.info(String(format: "receiver %08x: device %d %@", t.location, index, linked ? "connected" : "disconnected"))
            ctl.async {
                let ours = self.device.map { $0.transport === t && $0.index == index } ?? false
                if ours {
                    // Apply state in arrival order; only the configuration work is delayed.
                    let generation = self.link.update(linked)
                    DispatchQueue.main.async {
                        self.status.connected = linked
                        self.onStatus?(self.status)
                        if !linked { self.onButtons?([]) }
                    }
                    guard linked else { return }
                    self.ctl.asyncAfter(deadline: .now() + 0.2) {
                        guard self.link.isCurrent(generation), let d = self.device else { return }
                        self.configure(d)
                        self.readBattery(d)
                    }
                } else if linked && (self.device == nil || !self.link.linked) {
                    // The Spotlight 2 occupies more than one receiver slot and may come back on another one.
                    self.ctl.asyncAfter(deadline: .now() + 0.2) { self.probe(t, index: index) }
                }
            }
            return
        }

        guard let rt, rt.location == t.location, r[1] == rt.index, r.count >= 8 else { return }
        let swid = r[3] & 0x0F, fn = r[3] >> 4
        guard swid == 0 else { return }   // responses to someone else's requests

        if r[2] == rt.reprog {
            if fn == 0 {
                var pressed = Set<UInt16>()
                for i in stride(from: 4, to: min(r.count - 1, 12), by: 2) {
                    let cid = UInt16(r[i]) << 8 | UInt16(r[i + 1])
                    if cid != 0 { pressed.insert(cid) }
                }
                        DispatchQueue.main.async { self.onButtons?(pressed) }
            } else if fn == 1 {
                let dx = Int(Int16(bitPattern: UInt16(r[4]) << 8 | UInt16(r[5])))
                let dy = Int(Int16(bitPattern: UInt16(r[6]) << 8 | UInt16(r[7])))
                DispatchQueue.main.async { self.onMotion?(dx, dy) }
            }
        } else if r[2] == rt.wireless, fn == 0 {
            // Wireless device status broadcast: the device reconnected and lost its config.
            ctl.asyncAfter(deadline: .now() + 0.1) { if let d = self.device { self.configure(d) } }
        } else if r[2] == rt.battery, fn == 0 {
            updateBattery(Array(r.dropFirst(4)))
        } else if Log.verbose {
            Log.debug("event: \(hex(r))")
        }
    }
}

/// Orders link notifications: state changes apply immediately, and delayed
/// configuration only runs if no newer notification arrived in the meantime.
struct LinkTracker {
    private(set) var linked = false
    private(set) var generation: UInt64 = 0

    @discardableResult
    mutating func update(_ linked: Bool) -> UInt64 {
        self.linked = linked
        generation &+= 1
        return generation
    }

    func isCurrent(_ generation: UInt64) -> Bool { linked && generation == self.generation }
}
