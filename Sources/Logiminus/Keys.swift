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

    /// Moves the mouse cursor to a point in global Cocoa coordinates (origin bottom-left
    /// of the primary display) without generating mouse events, so the app underneath
    /// doesn't react (and doesn't reset the cursor image).
    static func warpMouse(to p: CGPoint) {
        CGWarpMouseCursorPosition(Self.cgPoint(fromCocoa: p, primaryHeight: NSScreen.screens.first?.frame.height ?? 0))
    }

    /// A real mouse move to `p`: hands the cursor back to the app underneath.
    static func moveMouse(to p: CGPoint) {
        let cg = Self.cgPoint(fromCocoa: p, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: cg, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Lets this (background, menu bar) app set the cursor image. Normally only the app
    /// under the cursor can; this window-server connection property (private, but used
    /// by cursor utilities for well over a decade) lifts that. Call once at startup.
    static func allowCursorChangesInBackground() {
        let cid = CGSMainConnectionID()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    /// Cocoa global coordinates → Core Graphics global coordinates (origin top-left of the primary display).
    static func cgPoint(fromCocoa p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
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

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> UInt32
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: UInt32, _ owner: UInt32, _ key: CFString, _ value: CFTypeRef) -> Int32
