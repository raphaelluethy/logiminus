import AppKit

/// Decides on which display a highlight starts.
///
/// Automatic mode looks for full-screen windows of the frontmost app (or of
/// Keynote/PowerPoint) — i.e. the slideshow — so the pointer appears on the
/// projector even when the mouse sits on the laptop's presenter screen.
/// Window bounds and owners are readable without Screen Recording permission.
final class ScreenPicker {
    static let auto = "auto"
    static let mouse = "mouse"

    private static let presenters: Set<String> = ["com.apple.iWork.Keynote", "com.microsoft.Powerpoint"]

    /// Display the user last left the highlight on, used to break ties between
    /// several full-screen windows (slideshow vs. presenter view).
    private var lastUsed: CGDirectDisplayID?

    func remember(_ screen: NSScreen?) { lastUsed = screen?.displayID }

    func startScreen(preference: String) -> NSScreen? {
        let screens = NSScreen.screens
        if preference != Self.auto && preference != Self.mouse,
           let s = screens.first(where: { $0.localizedName == preference }) {
            return s
        }
        if preference == Self.auto, screens.count > 1, let s = presentationScreen() { return s }
        return mouseScreen()
    }

    /// The display showing a running slideshow, or nil when nothing is presented full screen.
    func presentationScreen() -> NSScreen? {
        let candidates = fullScreenPresentationScreens()
        if candidates.count <= 1 { return candidates.first }
        if let last = lastUsed, let s = candidates.first(where: { $0.displayID == last }) { return s }
        // Presentation apps put the slideshow on the secondary display by default.
        return candidates.first(where: { $0 != NSScreen.screens.first }) ?? candidates[0]
    }

    func mouseScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    /// Screens fully covered by an on-screen window of the frontmost app or a presentation app.
    private func fullScreenPresentationScreens() -> [NSScreen] {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var pids = Set(NSWorkspace.shared.runningApplications
            .filter { Self.presenters.contains($0.bundleIdentifier ?? "") }
            .map(\.processIdentifier))
        if let front { pids.insert(front) }
        pids.remove(ProcessInfo.processInfo.processIdentifier)

        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var result: [NSScreen] = []
        for w in info {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"] else { continue }
            // CG window bounds have a top-left origin on the primary display.
            let frame = CGRect(x: x, y: primaryHeight - y - height, width: width, height: height)
            for s in NSScreen.screens where !result.contains(s) && frame.contains(s.frame.insetBy(dx: 1, dy: 1)) {
                result.append(s)
            }
        }
        return result
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
