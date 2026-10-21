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

    /// Left click at the current mouse position.
    static func click() {
        let p = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}

/// Start/stop the slideshow in whatever presentation app is in front.
enum PresentationControl {
    /// `presenting` comes from window detection (a full-screen slideshow is up), so
    /// switching apps or ending the show from the keyboard can't desync it.
    /// Returns true when a presentation was started (false when stopped).
    @discardableResult
    static func toggle(presenting: Bool) -> Bool {
        if presenting {
            Keys.tap(kVK_Escape)
            return false
        }
        switch NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" {
        case "com.apple.iWork.Keynote":
            Keys.tap(kVK_ANSI_P, [.maskCommand, .maskAlternate])
        case "com.microsoft.Powerpoint":
            Keys.tap(kVK_Return, [.maskCommand, .maskShift])
        default:
            // Google Slides & most web/other presenters.
            Keys.tap(kVK_Return, [.maskCommand])
        }
        return true
    }
}
