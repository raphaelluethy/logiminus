import Foundation

/// One Euro filter (Casiez et al., CHI 2012): a low-pass filter whose cutoff rises
/// with speed. Slow movement is smoothed hard (kills hand/gyro jitter), fast
/// movement passes through almost unfiltered (no lag on big sweeps).
struct OneEuroFilter {
    /// Cutoff (Hz) at rest; lower = smoother but more lag when slow.
    var minCutoff: Double
    /// How fast the cutoff grows with speed (per unit/s).
    var beta: Double
    /// Cutoff (Hz) for the speed estimate itself.
    var derivativeCutoff = 1.0

    private var value: Double?
    private var derivative = 0.0
    private var lastTime: TimeInterval?

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func reset() {
        value = nil
        derivative = 0
        lastTime = nil
    }

    mutating func filter(_ x: Double, at time: TimeInterval) -> Double {
        guard let prev = value, let last = lastTime else {
            value = x
            lastTime = time
            return x
        }
        let dt = max(time - last, 1e-3)
        lastTime = time
        let rawDerivative = (x - prev) / dt
        derivative += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (rawDerivative - derivative)
        let cutoff = minCutoff + beta * abs(derivative)
        let v = prev + Self.alpha(cutoff: cutoff, dt: dt) * (x - prev)
        value = v
        return v
    }
}

/// Smooths a 2D pointer position; both axes share one speed-dependent cutoff
/// so diagonal movement doesn't get skewed.
struct PointSmoother {
    private var x: OneEuroFilter
    private var y: OneEuroFilter
    private var speed = OneEuroFilter(minCutoff: 1, beta: 0)   // smoothed output speed (px/s)
    private var currentSpeed = 0.0
    private var last: CGPoint?
    private var lastTime: TimeInterval?
    let level: Smoothing

    init(level: Smoothing) {
        self.level = level
        x = OneEuroFilter(minCutoff: level.minCutoff, beta: 0)
        y = OneEuroFilter(minCutoff: level.minCutoff, beta: 0)
    }

    mutating func reset() {
        x.reset(); y.reset(); speed.reset()
        currentSpeed = 0
        last = nil
        lastTime = nil
    }

    mutating func smooth(_ p: CGPoint, at time: TimeInterval) -> CGPoint {
        guard level != .off else { return p }
        let cutoff = level.minCutoff + level.beta * currentSpeed
        x.minCutoff = cutoff
        y.minCutoff = cutoff
        let out = CGPoint(x: x.filter(p.x, at: time), y: y.filter(p.y, at: time))
        // Speed of the smoothed output rather than the raw input: jitter barely moves
        // it, so noise at rest can't loosen the filter, while real motion still does.
        if let last, let lastTime {
            let dt = max(time - lastTime, 1e-3)
            currentSpeed = speed.filter(hypot(out.x - last.x, out.y - last.y) / dt, at: time)
        }
        last = out
        lastTime = time
        return out
    }
}

/// Soft dead zone on the raw motion deltas. Holding the remote still produces a
/// trickle of ±1-unit deltas that would add up to a slow drift; this drops motion
/// whose recent average magnitude is that small and ramps smoothly to full motion.
struct DeltaGate {
    let level: Smoothing
    private var average = 0.0   // recent mean delta magnitude (device units per event)

    init(level: Smoothing) { self.level = level }

    mutating func apply(dx: Double, dy: Double) -> (Double, Double) {
        guard let (lo, hi) = level.deadZone else { return (dx, dy) }
        average += 0.3 * (hypot(dx, dy) - average)
        let t = min(max((average - lo) / (hi - lo), 0), 1)
        let gain = t * t * (3 - 2 * t)   // smoothstep
        return (dx * gain, dy * gain)
    }
}

enum Smoothing: Int, CaseIterable {
    case off = 0, low, medium, high

    var title: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// Cutoff at rest (Hz). Raw motion arrives at ~100 Hz.
    var minCutoff: Double {
        switch self {
        case .off: return 0
        case .low: return 2.5
        case .medium: return 1.2
        case .high: return 0.6
        }
    }

    /// Average delta magnitude (device units/event) below which motion is dropped,
    /// and above which it passes unchanged. At rest the remote reports ~1 unit/event.
    var deadZone: (Double, Double)? {
        switch self {
        case .off: return nil
        case .low: return (0.8, 2.0)
        case .medium: return (1.1, 2.5)
        case .high: return (1.4, 3.2)
        }
    }

    /// Cutoff gain per px/s of pointer speed: ~1500 px/s (a brisk sweep) lifts it to ~10 Hz.
    var beta: Double { self == .off ? 0 : 0.006 }
}
