import XCTest
@testable import MonitorCore

final class TouchBarNavigationTests: XCTestCase {
    private func steps(_ ids: Range<Int>) -> [ExecutionStep] { ids.map { ExecutionStep(id: "\($0)", kind: "commandExecution", title: "步骤 \($0)", symbol: "terminal") } }
    func testTaskToStepsToContentAndBackNeverNeedsScreenPanel() {
        var nav = TouchBarNavigation()
        nav.enter(taskID: "task"); nav.update(steps(0..<8))
        XCTAssertEqual(nav.mode, .steps); XCTAssertEqual(nav.visible.map(\.id), ["5", "6", "7"])
        nav.open("6"); XCTAssertEqual(nav.mode, .content); XCTAssertEqual(nav.selected?.id, "6")
        nav.back(); XCTAssertEqual(nav.mode, .steps); XCTAssertEqual(nav.start, 5)
        nav.back(); XCTAssertEqual(nav.mode, .overview); XCTAssertNil(nav.taskID); XCTAssertTrue(nav.steps.isEmpty)
    }
    func testBrowseEarlierWithoutNewEventsMovingReadingPosition() {
        var nav = TouchBarNavigation(); nav.enter(taskID: "a"); nav.update(steps(0..<8)); nav.previous()
        XCTAssertEqual(nav.visible.map(\.id), ["2", "3", "4"])
        nav.update(steps(0..<12)); XCTAssertEqual(nav.visible.map(\.id), ["2", "3", "4"])
        nav.open("3"); nav.update(steps(0..<13)); XCTAssertEqual(nav.selected?.id, "3")
        nav.latest(); XCTAssertEqual(nav.visible.map(\.id), ["10", "11", "12"]); XCTAssertFalse(nav.canNext)
    }
    func testHistoryPrependingPreservesLiveAnchorAndContent() {
        var nav = TouchBarNavigation(); nav.enter(taskID: "a"); nav.update(steps(5..<10)); nav.open("8")
        nav.update(steps(0..<11)); XCTAssertEqual(nav.selected?.id, "8"); XCTAssertEqual(nav.visible.first?.id, "7")
        nav.update(steps(20..<22)); XCTAssertEqual(nav.mode, .steps); XCTAssertNil(nav.selectedID)
        nav.enter(taskID: "b"); XCTAssertTrue(nav.steps.isEmpty); XCTAssertNil(nav.selectedID)
    }
    func testEmptyAndShortListsClampPaging() {
        var nav = TouchBarNavigation(); nav.enter(taskID: "a"); nav.next(); nav.previous(); nav.open("missing")
        XCTAssertEqual(nav.start, 0); XCTAssertEqual(nav.mode, .steps)
        nav.update(steps(0..<2)); nav.next(); XCTAssertEqual(nav.start, 0); XCTAssertFalse(nav.canNext)
    }
}
