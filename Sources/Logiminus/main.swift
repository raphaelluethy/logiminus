import AppKit
import Foundation

let usage = """
logiminus — Logitech Spotlight 2 driver

usage:
  logiminus enable | disable | toggle | status   control the running menu bar agent
  logiminus haptic <waveform>                     play a haptic waveform on the remote
  logiminus timer start | stop                    presentation timer
  logiminus quit                                  quit the agent
  logiminus agent                                 run the menu bar agent in the foreground
  logiminus monitor                               (debug) print HID++ traffic, no agent
"""

let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }

/// Path of the enclosing .app bundle, if this binary lives inside one.
func appBundleURL() -> URL? {
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    if !url.path.hasPrefix("/") { url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(url.path) }
    while url.path != "/" {
        if url.pathExtension == "app" { return url }
        url.deleteLastPathComponent()
    }
    return nil
}

func runAgent() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let agent = Agent()
    agent.start()
    withExtendedLifetime(agent) { app.run() }
    exit(0)
}

func launchAgentAndSend(_ command: String) -> String? {
    if let reply = IPC.send(command) { return reply }
    guard let bundle = appBundleURL() else {
        FileHandle.standardError.write(Data("agent not running (start it with `logiminus agent` or the app)\n".utf8))
        return nil
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", bundle.path]
    try? p.run()
    p.waitUntilExit()
    for _ in 0..<50 {
        usleep(100_000)
        if let reply = IPC.send(command) { return reply }
    }
    return nil
}

switch args.first {
case nil:
    if isatty(STDIN_FILENO) == 0 { runAgent() }   // launched from Finder / `open`
    print(usage)
case "agent", "run":
    runAgent()
case "enable", "toggle":
    guard let r = launchAgentAndSend(args.joined(separator: " ")) else { exit(1) }
    print(r)
case "disable", "status", "haptic", "timer", "quit":
    guard let r = IPC.send(args.joined(separator: " ")) else {
        print(args.first == "status" ? "not running" : "agent not running")
        exit(args.first == "disable" || args.first == "quit" ? 0 : 1)
    }
    print(r)
    if r.hasPrefix("error") { exit(1) }
case "monitor":
    Monitor.run()
case "-h", "--help", "help":
    print(usage)
default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
