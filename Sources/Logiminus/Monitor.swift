import Foundation

/// `logiminus monitor [--divert]`: prints device discovery and events without
/// the agent. With --divert it takes over the buttons (restored on Ctrl-C).
enum Monitor {
    static func run() -> Never {
        Log.echo = true
        let divert = CommandLine.arguments.contains("--divert")
        if CommandLine.arguments.contains("-v") { Log.verbose = true }
        setvbuf(stdout, nil, _IOLBF, 0)
        let c = SpotlightController(diverted: divert, manage: divert)
        c.onButtons = { print("buttons:", $0.map { String(format: "0x%04x", $0) }.sorted()) }
        var acc = (0, 0, 0)
        c.onMotion = { dx, dy in
            acc.0 += dx; acc.1 += dy; acc.2 += 1
            if acc.2 % 25 == 0 { print("motion: \(acc.2) events, sum dx=\(acc.0) dy=\(acc.1)") }
        }
        c.onStatus = { s in print("status:", s) }
        c.start()
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sig.setEventHandler {
            if divert { c.restoreNative() }
            exit(0)
        }
        sig.resume()
        // Debug commands on stdin: "<feature hex> <function> [param bytes hex...]"
        DispatchQueue.global().async {
            while let line = readLine() {
                let p = line.split(separator: " ")
                guard p.count >= 2, let f = UInt16(p[0], radix: 16), let fn = UInt8(p[1], radix: 16) else { continue }
                let params = p.dropFirst(2).compactMap { UInt8($0, radix: 16) }
                c.raw(feature: f, function: fn, params: params) { print("=", $0) }
            }
        }
        withExtendedLifetime(sig) { dispatchMain() }
    }
}
