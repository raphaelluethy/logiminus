import Foundation
import IOKit.hid

// HID++ transport over the vendor-defined collection (usage page 0xFF00) of a
// Logitech receiver. All IOHID callbacks run on a dedicated thread; requests are
// synchronous and must be issued from a background queue (never the HID thread).

enum HIDPPError: Error, CustomStringConvertible {
    case timeout
    case hidpp10(UInt8)   // receiver error (0x8F), 0x04 = device offline / asleep
    case hidpp20(UInt8)   // device feature error (0xFF)
    case featureMissing(UInt16)
    case writeFailed(IOReturn)

    var description: String {
        switch self {
        case .timeout: return "timeout"
        case .hidpp10(let e): return String(format: "HID++1.0 error 0x%02x", e)
        case .hidpp20(let e): return String(format: "HID++2.0 error 0x%02x", e)
        case .featureMissing(let f): return String(format: "feature 0x%04x not supported", f)
        case .writeFailed(let r): return String(format: "write failed 0x%08x", r)
        }
    }

    var isOffline: Bool {
        if case .hidpp10(let e) = self { return e == 0x04 || e == 0x08 }
        if case .timeout = self { return true }
        return false
    }
}

enum ReportID {
    static let short: UInt8 = 0x10   // 7 bytes
    static let long: UInt8 = 0x11    // 20 bytes
}

/// Software id used in our requests. Responses are broadcast to every client that
/// has the interface open (e.g. Options+), so a distinct id avoids cross-talk.
let ourSoftwareID: UInt8 = 0x0D

func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

final class HIDPPTransport {
    let device: IOHIDDevice
    let location: Int
    let productID: Int
    let product: String
    /// Direct Bluetooth LE connection (HID++ in the 0xFF43 collection, device index 0xFF).
    let isBluetooth: Bool
    var onReport: (([UInt8]) -> Void)?

    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let lock = NSLock()
    private var pending: Pending?

    private final class Pending {
        let deviceIndex: UInt8
        let featureIndex: UInt8
        let functionSW: UInt8
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[UInt8], HIDPPError>?
        init(deviceIndex: UInt8, featureIndex: UInt8, functionSW: UInt8) {
            self.deviceIndex = deviceIndex
            self.featureIndex = featureIndex
            self.functionSW = functionSW
        }
    }

    init(device: IOHIDDevice) {
        self.device = device
        location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0
        productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
        isBluetooth = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "")
            .localizedCaseInsensitiveContains("bluetooth")
    }

    var kind: String { isBluetooth ? "Bluetooth" : "USB receiver" }

    private(set) var openError: IOReturn = kIOReturnSuccess

    deinit { inputBuffer.deallocate() }

    /// Must be called on the HID thread.
    func open(runLoop: CFRunLoop) -> Bool {
        openError = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openError == kIOReturnSuccess else { return false }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            let me = Unmanaged<HIDPPTransport>.fromOpaque(ctx).takeUnretainedValue()
            me.handle(Array(UnsafeBufferPointer(start: report, count: length)))
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        return true
    }

    func close() {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        lock.lock()
        pending?.result = .failure(.timeout)
        pending?.semaphore.signal()
        pending = nil
        lock.unlock()
    }

    private func handle(_ r: [UInt8]) {
        guard r.count >= 4, r[0] == ReportID.short || r[0] == ReportID.long else { return }
        if Log.verbose { Log.debug("<- \(hex(r))") }
        lock.lock()
        if let p = pending, r[1] == p.deviceIndex {
            if r[2] == p.featureIndex && r[3] == p.functionSW {
                p.result = .success(Array(r.dropFirst(4)))
            } else if r.count >= 6 && r[2] == 0xFF && r[3] == p.featureIndex && r[4] == p.functionSW {
                p.result = .failure(.hidpp20(r[5]))
            } else if r.count >= 6 && r[2] == 0x8F && r[3] == p.featureIndex && r[4] == p.functionSW {
                p.result = .failure(.hidpp10(r[5]))
            }
            if p.result != nil {
                pending = nil
                lock.unlock()
                p.semaphore.signal()
                return
            }
        }
        lock.unlock()
        onReport?(r)
    }

    private func write(_ bytes: [UInt8]) throws {
        var b = bytes
        let size = b[0] == ReportID.short ? 7 : 20
        if b.count < size { b += [UInt8](repeating: 0, count: size - b.count) }
        if Log.verbose { Log.debug("-> \(hex(b))") }
        let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(b[0]), b, b.count)
        if r != kIOReturnSuccess { throw HIDPPError.writeFailed(r) }
    }

    /// Sends a HID++ 2.0 request (long report) and waits for its response payload
    /// (the 16 bytes following the function/software-id byte).
    func request(device index: UInt8, feature: UInt8, function: UInt8, params: [UInt8] = [],
                 timeout: TimeInterval = 1.0) throws -> [UInt8] {
        let fnsw = (function << 4) | ourSoftwareID
        let p = Pending(deviceIndex: index, featureIndex: feature, functionSW: fnsw)
        lock.lock(); pending = p; lock.unlock()
        do {
            try write([ReportID.long, index, feature, fnsw] + params)
        } catch {
            lock.lock(); pending = nil; lock.unlock()
            throw error
        }
        if p.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); if pending === p { pending = nil }; lock.unlock()
            throw HIDPPError.timeout
        }
        return try p.result!.get()
    }
}

/// A HID++ 2.0 device reachable through a transport at a device index.
final class HIDPPDevice {
    let transport: HIDPPTransport
    let index: UInt8
    private(set) var features: [UInt16: UInt8] = [0x0000: 0]

    init(transport: HIDPPTransport, index: UInt8) {
        self.transport = transport
        self.index = index
    }

    /// Root.ping — returns the protocol version (major, minor).
    func ping(timeout: TimeInterval = 0.5) throws -> (UInt8, UInt8) {
        let r = try transport.request(device: index, feature: 0, function: 1, params: [0, 0, 0x5A], timeout: timeout)
        return (r[0], r[1])
    }

    @discardableResult
    func featureIndex(_ feature: UInt16) throws -> UInt8 {
        if let i = features[feature] { return i }
        let r = try transport.request(device: index, feature: 0, function: 0,
                                      params: [UInt8(feature >> 8), UInt8(feature & 0xFF)])
        guard r[0] != 0 else { throw HIDPPError.featureMissing(feature) }
        features[feature] = r[0]
        return r[0]
    }

    func hasFeature(_ feature: UInt16) -> Bool { (try? featureIndex(feature)) != nil }

    /// Calls a feature function. The remote sleeps after a few seconds idle and the
    /// first request only wakes it up, so offline errors are retried a few times.
    func call(_ feature: UInt16, _ function: UInt8, _ params: [UInt8] = [], timeout: TimeInterval = 1.0,
              retries: Int = 3) throws -> [UInt8] {
        let idx = try featureIndex(feature)
        var attempt = 0
        while true {
            do {
                return try transport.request(device: index, feature: idx, function: function, params: params, timeout: timeout)
            } catch let e as HIDPPError where e.isOffline && attempt < retries {
                attempt += 1
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    func name() throws -> String {
        let len = Int(try call(Feature.deviceName, 0)[0])
        var bytes: [UInt8] = []
        while bytes.count < len {
            let chunk = try call(Feature.deviceName, 1, [UInt8(bytes.count)])
            bytes += chunk.prefix(len - bytes.count)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func invalidateFeatures() { features = [0x0000: 0] }
}

enum Feature {
    static let root: UInt16 = 0x0000
    static let deviceName: UInt16 = 0x0005
    static let unifiedBattery: UInt16 = 0x1004
    static let wirelessStatus: UInt16 = 0x1D4B
    static let reprogControls: UInt16 = 0x1B04
    static let haptics: UInt16 = 0x19B0
    static let forceSensing: UInt16 = 0x19C0
    static let pointerSpeed: UInt16 = 0x2205
}

/// Owns the HID thread and the IOHIDManager watching Logitech vendor interfaces.
final class HIDManager {
    var onAdded: ((HIDPPTransport) -> Void)?
    var onRemoved: ((HIDPPTransport) -> Void)?
    var onPermissionNeeded: (() -> Void)?
    var onPermissionGranted: (() -> Void)?

    private var manager: IOHIDManager!
    private var transports: [IOHIDDevice: HIDPPTransport] = [:]
    private var runLoop: CFRunLoop!
    private let ready = DispatchSemaphore(value: 0)

    func start() {
        let t = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matching: [[String: Any]] = [
                // Receivers: vendor collection is a top-level device.
                [kIOHIDVendorIDKey: 0x046D, kIOHIDPrimaryUsagePageKey: 0xFF00],
                // Bluetooth LE devices: HID++ lives in a secondary 0xFF43/0x0202 collection.
                [kIOHIDVendorIDKey: 0x046D, kIOHIDDeviceUsagePageKey: 0xFF43, kIOHIDDeviceUsageKey: 0x0202],
            ]
            IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
                Unmanaged<HIDManager>.fromOpaque(ctx!).takeUnretainedValue().added(device)
            }, ctx)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
                Unmanaged<HIDManager>.fromOpaque(ctx!).takeUnretainedValue().removed(device)
            }, ctx)
            IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "logiminus.hid"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
    }

    private func added(_ device: IOHIDDevice) {
        let t = HIDPPTransport(device: device)
        guard t.open(runLoop: runLoop) else {
            Log.info(String(format: "could not open %@ (loc %08x): 0x%08x", t.product, t.location, t.openError))
            // Bluetooth remotes also present a keyboard, which needs Input Monitoring access.
            if t.openError == kIOReturnNotPermitted {
                blocked.insert(device)
                onPermissionNeeded?()
                retryWhenPermitted()
            }
            return
        }
        transports[device] = t
        Log.info(String(format: "attached %@ pid=%04x loc=%08x", t.product, t.productID, t.location))
        onAdded?(t)
    }

    /// Devices that could not be opened for lack of Input Monitoring access.
    private var blocked = Set<IOHIDDevice>()
    private var retryTimer: CFRunLoopTimer?

    /// Polls the permission and opens the blocked devices once it is granted.
    private func retryWhenPermitted() {
        guard retryTimer == nil else { return }
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 2, 2, 0, 0) { [weak self] timer in
            guard let self, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
            CFRunLoopTimerInvalidate(timer)
            self.retryTimer = nil
            let devices = self.blocked
            self.blocked.removeAll()
            devices.forEach(self.added)
            self.onPermissionGranted?()
        }
        retryTimer = timer
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    private func removed(_ device: IOHIDDevice) {
        blocked.remove(device)
        guard let t = transports.removeValue(forKey: device) else { return }
        Log.info(String(format: "detached %@ loc=%08x", t.product, t.location))
        t.close()
        onRemoved?(t)
    }
}
