import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Synthesizes keystrokes. Posting only — we never install an event tap, so
/// the keyboard path of the system is left untouched.
enum Keys {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static func tap(_ key: Int, _ flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}

/// Start/stop the slideshow in whatever presentation app is in front.
final class PresentationControl {
    private(set) var presenting = false
    private var presentingApp: String?

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let self, self.presenting, app?.bundleIdentifier != self.presentingApp { self.presenting = false }
        }
    }

    /// Returns true when a presentation was started (false when stopped).
    @discardableResult
    func toggle() -> Bool {
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if presenting {
            Keys.tap(kVK_Escape)
            presenting = false
            return false
        }
        switch bundle {
        case "com.apple.iWork.Keynote":
            Keys.tap(kVK_ANSI_P, [.maskCommand, .maskAlternate])
        case "com.microsoft.Powerpoint":
            Keys.tap(kVK_Return, [.maskCommand, .maskShift])
        default:
            // Google Slides & most web/other presenters.
            Keys.tap(kVK_Return, [.maskCommand])
        }
        presenting = true
        presentingApp = bundle
        return true
    }
}
