import Foundation
import os

enum Log {
    static var verbose = ProcessInfo.processInfo.environment["LOGIMINUS_DEBUG"] != nil
    static var echo = false   // also print to stderr (CLI debug commands)
    private static let logger = Logger(subsystem: "gg.lty.logiminus", category: "main")

    static func info(_ s: String) {
        logger.info("\(s, privacy: .public)")
        if echo || verbose { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    }

    static func debug(_ s: String) {
        logger.debug("\(s, privacy: .public)")
        if echo || verbose { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    }
}

enum TapAction: String, CaseIterable {
    case none, click

    var title: String { self == .none ? "Nothing" : "Left click" }
}

enum Effect: String, CaseIterable {
    case pointer, spotlight, none

    var title: String {
        switch self {
        case .pointer: return "Pointer"
        case .spotlight: return "Spotlight"
        case .none: return "Nothing"
        }
    }
}

/// Whether the system mouse cursor is moved along with the highlight.
///
/// A window share (Teams, Zoom, Meet, … sharing one app instead of the whole screen)
/// captures only that app's pixels plus the system cursor, so the overlay never shows
/// up for the viewers — the cursor does.
enum CursorFollow: String, CaseIterable {
    case windowed, always, never

    var title: String {
        switch self {
        case .windowed: return "Follows the pointer outside slideshows"
        case .always: return "Always follows the pointer"
        case .never: return "Stays where it is"
        }
    }

    /// `presenting`: a full-screen slideshow is on screen (where moving the mouse would
    /// make the presentation app show its own cursor and controls).
    func applies(presenting: Bool) -> Bool {
        switch self {
        case .windowed: return !presenting
        case .always: return true
        case .never: return false
        }
    }
}

/// Persistent user settings (UserDefaults domain gg.lty.logiminus).
final class Settings {
    static let shared = Settings()
    // Inside the app bundle the suite is the app's own domain, which UserDefaults(suiteName:) rejects.
    private let d = Bundle.main.bundleIdentifier == "gg.lty.logiminus" ? .standard : UserDefaults(suiteName: "gg.lty.logiminus")!

    private init() {
        d.register(defaults: [
            "enabled": true,
            "lightEffect": Effect.pointer.rawValue,
            "hardEffect": Effect.spotlight.rawValue,
            "pointerSpeed": 1.0,
            "spotlightSize": 0.18,     // radius as a fraction of screen height
            "dimOpacity": 0.75,
            "pointerSize": 11.0,
            "hapticsEnabled": true,
            "hapticLevel": 35,
            "timerMinutes": 0,
            "startTimerWithPresentation": true,
            "startScreen": "auto",
            "tapAction": TapAction.none.rawValue,
            "smoothing": Smoothing.medium.rawValue,
            "cursorFollow": CursorFollow.windowed.rawValue,
        ])
    }

    var enabled: Bool { get { d.bool(forKey: "enabled") } set { d.set(newValue, forKey: "enabled") } }
    var lightEffect: Effect {
        get { Effect(rawValue: d.string(forKey: "lightEffect") ?? "") ?? .pointer }
        set { d.set(newValue.rawValue, forKey: "lightEffect") }
    }
    var hardEffect: Effect {
        get { Effect(rawValue: d.string(forKey: "hardEffect") ?? "") ?? .spotlight }
        set { d.set(newValue.rawValue, forKey: "hardEffect") }
    }
    var pointerSpeed: Double { get { d.double(forKey: "pointerSpeed") } set { d.set(newValue, forKey: "pointerSpeed") } }
    var spotlightSize: Double { get { d.double(forKey: "spotlightSize") } set { d.set(newValue, forKey: "spotlightSize") } }
    var dimOpacity: Double { get { d.double(forKey: "dimOpacity") } set { d.set(newValue, forKey: "dimOpacity") } }
    var pointerSize: Double { get { d.double(forKey: "pointerSize") } set { d.set(newValue, forKey: "pointerSize") } }
    var hapticsEnabled: Bool { get { d.bool(forKey: "hapticsEnabled") } set { d.set(newValue, forKey: "hapticsEnabled") } }
    var hapticLevel: Int { get { d.integer(forKey: "hapticLevel") } set { d.set(newValue, forKey: "hapticLevel") } }
    var timerMinutes: Int { get { d.integer(forKey: "timerMinutes") } set { d.set(newValue, forKey: "timerMinutes") } }
    var smoothing: Smoothing {
        get { Smoothing(rawValue: d.integer(forKey: "smoothing")) ?? .medium }
        set { d.set(newValue.rawValue, forKey: "smoothing") }
    }
    var tapAction: TapAction {
        get { TapAction(rawValue: d.string(forKey: "tapAction") ?? "") ?? .none }
        set { d.set(newValue.rawValue, forKey: "tapAction") }
    }
    var cursorFollow: CursorFollow {
        get { CursorFollow(rawValue: d.string(forKey: "cursorFollow") ?? "") ?? .windowed }
        set { d.set(newValue.rawValue, forKey: "cursorFollow") }
    }
    /// "auto", "mouse" or a display UUID (older versions stored the display name).
    var startScreen: String { get { d.string(forKey: "startScreen") ?? "auto" } set { d.set(newValue, forKey: "startScreen") } }
    var startTimerWithPresentation: Bool {
        get { d.bool(forKey: "startTimerWithPresentation") }
        set { d.set(newValue, forKey: "startTimerWithPresentation") }
    }
}
