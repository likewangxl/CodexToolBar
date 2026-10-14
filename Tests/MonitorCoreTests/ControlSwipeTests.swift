import XCTest
@testable import MonitorCore

final class ControlSwipeTests: XCTestCase {
    func testSingleFingerRemainsTap() {
        var swipe = ControlSwipe()
        XCTAssertNil(swipe.update(count: 1, x: 10, time: 0))
        XCTAssertNil(swipe.update(count: 0, x: 10, time: 1))
        XCTAssertFalse(swipe.captured)
    }
    func testThreeFingersArrivingSeparatelyNeverChangeVolume() {
        var swipe = ControlSwipe()
        XCTAssertNil(swipe.update(count: 2, x: 0, time: 0))
        XCTAssertNil(swipe.update(count: 2, x: 30, time: 0.1))
        XCTAssertNil(swipe.update(count: 3, x: 35, time: 0.12))
        XCTAssertNil(swipe.update(count: 3, x: 55, time: 0.2))
        XCTAssertEqual(swipe.update(count: 3, x: 60, time: 0.3), 0)
        XCTAssertEqual(swipe.control, .brightness)
        XCTAssertEqual(swipe.update(count: 3, x: 100, time: 0.4), 0.1)
    }
    func testThresholdDirectionAndFingerChangeCancel() {
        var swipe = ControlSwipe()
        _ = swipe.update(count: 2, x: 100, time: 0)
        XCTAssertNil(swipe.update(count: 2, x: 105, time: 0.2))
        XCTAssertEqual(swipe.update(count: 2, x: 120, time: 0.3), 0)
        XCTAssertEqual(swipe.control, .volume)
        XCTAssertEqual(swipe.update(count: 2, x: 80, time: 0.4), -0.1)
        XCTAssertNil(swipe.update(count: 3, x: 90, time: 0.5))
        XCTAssertNil(swipe.update(count: 2, x: 140, time: 0.8))
        XCTAssertTrue(swipe.captured)
    }
    func testLiftAndUnsupportedFingerCountsConsumeWithoutAction() {
        for count in [1, 4] {
            var swipe = ControlSwipe()
            _ = swipe.update(count: 2, x: 0, time: 0)
            XCTAssertNil(swipe.update(count: count, x: 40, time: 0.2))
            XCTAssertNil(swipe.update(count: 2, x: 100, time: 1))
            XCTAssertNil(swipe.control)
            XCTAssertTrue(swipe.captured)
        }
    }
}
