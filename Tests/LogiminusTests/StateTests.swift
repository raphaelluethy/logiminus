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

final class CursorFollowTests: XCTestCase {
    func testWindowedOnlyOutsideSlideshows() {
        XCTAssertTrue(CursorFollow.windowed.applies(presenting: false))
        XCTAssertFalse(CursorFollow.windowed.applies(presenting: true))
        XCTAssertTrue(CursorFollow.always.applies(presenting: true))
        XCTAssertFalse(CursorFollow.never.applies(presenting: false))
    }

    func testCocoaToCoreGraphicsFlipsY() {
        // Top-left corner of a 1000 pt tall primary display, and a point on a display below it.
        XCTAssertEqual(Keys.cgPoint(fromCocoa: CGPoint(x: 10, y: 1000), primaryHeight: 1000), CGPoint(x: 10, y: 0))
        XCTAssertEqual(Keys.cgPoint(fromCocoa: CGPoint(x: 10, y: -200), primaryHeight: 1000), CGPoint(x: 10, y: 1200))
    }
}
