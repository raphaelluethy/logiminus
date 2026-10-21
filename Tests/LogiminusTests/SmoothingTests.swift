import XCTest
@testable import logiminus

final class SmoothingTests: XCTestCase {
    private let rate = 100.0   // Spotlight raw XY rate (Hz)

    /// Holding still with ±3 px of jitter: the output should wobble far less.
    func testJitterAtRestIsDamped() {
        var s = PointSmoother(level: .medium)
        var outs: [CGPoint] = []
        var rng = SystemRandomNumberGenerator()
        for i in 0..<300 {
            let p = CGPoint(x: 500 + Double.random(in: -3...3, using: &rng), y: 300 + Double.random(in: -3...3, using: &rng))
            let o = s.smooth(p, at: Double(i) / rate)
            if i > 100 { outs.append(o) }
        }
        let xs = outs.map(\.x)
        XCTAssertLessThan(xs.max()! - xs.min()!, 2.0, "output spread should be well under the 6 px input spread")
    }

    /// A fast sweep (2000 px/s) should lag only a few pixels behind.
    func testFastMovementHasLittleLag() {
        var s = PointSmoother(level: .medium)
        var last = CGPoint.zero
        for i in 0..<100 {
            let x = Double(i) * 20   // 20 px per event at 100 Hz
            last = s.smooth(CGPoint(x: x, y: 0), at: Double(i) / rate)
        }
        XCTAssertLessThan(99 * 20 - last.x, 40)
    }

    /// Slow movement still arrives at the target once it stops.
    func testConvergesWhenStopped() {
        var s = PointSmoother(level: .high)
        var o = CGPoint.zero
        for i in 0..<300 { o = s.smooth(CGPoint(x: i < 50 ? Double(i) : 50, y: 0), at: Double(i) / rate) }
        XCTAssertEqual(o.x, 50, accuracy: 0.5)
    }

    func testOffPassesThrough() {
        var s = PointSmoother(level: .off)
        let p = CGPoint(x: 12.5, y: -3)
        _ = s.smooth(.zero, at: 0)
        XCTAssertEqual(s.smooth(p, at: 0.01), p)
    }
}

final class DeltaGateTests: XCTestCase {
    /// The resting pattern captured from the remote: ±1 deltas, often several in a row.
    func testRestingTrickleBarelyMoves() {
        var g = DeltaGate(level: .medium)
        let rest: [(Double, Double)] = [(0, 1), (0, 1), (-1, 0), (-1, 0), (-1, 0), (-1, 0), (-1, 0), (0, 1), (0, 1), (0, 1),
                                         (-1, 0), (-1, -1), (-1, 0), (-1, 0), (1, 0), (-1, 0), (-1, 0), (1, 0), (-1, 0), (-1, 0)]
        var x = 0.0, y = 0.0, rawX = 0.0
        for (dx, dy) in rest + rest + rest {
            let (gx, gy) = g.apply(dx: dx, dy: dy)
            x += gx; y += gy; rawX += dx
        }
        XCTAssertLessThan(abs(x), abs(rawX) * 0.1, "drift should be mostly removed")
        XCTAssertLessThan(abs(y), 2)
    }

    func testDeliberateMotionPassesUnchanged() {
        var g = DeltaGate(level: .medium)
        var out = (0.0, 0.0)
        for _ in 0..<10 { out = g.apply(dx: 4, dy: -3) }
        XCTAssertEqual(out.0, 4, accuracy: 0.01)
        XCTAssertEqual(out.1, -3, accuracy: 0.01)
    }

    func testOffIsIdentity() {
        var g = DeltaGate(level: .off)
        let out = g.apply(dx: 1, dy: 0)
        XCTAssertEqual(out.0, 1)
    }
}
