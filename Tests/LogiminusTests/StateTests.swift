import XCTest
@testable import logiminus

final class LinkTrackerTests: XCTestCase {
    /// Connect then disconnect in quick succession: the delayed configuration of the
    /// connect must not resurrect the link.
    func testDisconnectAfterConnectWins() {
        var link = LinkTracker()
        let connected = link.update(true)
        link.update(false)
        XCTAssertFalse(link.linked)
        XCTAssertFalse(link.isCurrent(connected))
    }

    func testOnlyLatestConnectIsCurrent() {
        var link = LinkTracker()
        let first = link.update(true)
        let second = link.update(true)
        XCTAssertFalse(link.isCurrent(first))
        XCTAssertTrue(link.isCurrent(second))
    }
}

final class PresentationTimerTests: XCTestCase {
    func testHugeDurationIsClampedInsteadOfOverflowing() {
        let t = PresentationTimer()
        t.start(minutes: 153_722_867_280_912_931)
        defer { t.stop() }
        let remaining = try! XCTUnwrap(t.remaining)
        XCTAssertLessThanOrEqual(remaining, 600 * 60)
        XCTAssertGreaterThan(remaining, 599 * 60)
    }

    func testStopClearsTimer() {
        let t = PresentationTimer()
        t.start(minutes: 5)
        t.stop()
        XCTAssertNil(t.remaining)
    }
}
