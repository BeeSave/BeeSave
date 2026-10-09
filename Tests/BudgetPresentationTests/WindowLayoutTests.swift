import XCTest
@testable import BudgetPresentation

final class WindowLayoutTests: XCTestCase {
    func testStandardFitsLargeDisplayAndCentersInLogicalPoints() {
        let screen = CGRect(x: 1920, y: 40, width: 1920, height: 1040)
        let frame = WindowLayout.centered(size: WindowLayout.workspaceSize, in: screen)
        XCTAssertEqual(frame.size, CGSize(width: 1440, height: 900))
        XCTAssertEqual(frame.midX, screen.midX); XCTAssertEqual(frame.midY, screen.midY)
    }
    func testSmallAndDisconnectedScreensKeepEveryEdgeAccessible() {
        let available = CGRect(x: -1280, y: 40, width: 1280, height: 740)
        let oldFrame = CGRect(x: 3000, y: -500, width: 1440, height: 960)
        let actual = WindowLayout.fitted(oldFrame, in: available)
        XCTAssertTrue(available.insetBy(dx: 24, dy: 24).contains(actual))
        XCTAssertEqual(actual.width, 1232); XCTAssertEqual(actual.height, 692)
        let tiny = CGRect(x: 0, y: 0, width: 20, height: 12)
        XCTAssertTrue(tiny.contains(WindowLayout.fitted(oldFrame, in: tiny)))
    }
    func testManualFrameIsPreservedIfItAlreadyFits() {
        let rect = CGRect(x: 125, y: 100, width: 1100, height: 760)
        XCTAssertEqual(WindowLayout.fitted(rect, in: CGRect(x: 0, y: 0, width: 1600, height: 1000)), rect)
        XCTAssertNotEqual(WindowLayout.accessSize, WindowLayout.workspaceSize)
    }
    func testNoticeChargesOnlyVisibleTimeAndRejectsStaleTimer() {
        var old = AppNotice("Курсы обновлены", kind: .success)
        XCTAssertFalse(old.elapse(3, token: old.id, visible: false))
        XCTAssertEqual(old.remaining, 4)
        XCTAssertFalse(old.elapse(3, token: old.id, visible: true))
        var next = AppNotice("Копия сохранена", kind: .success)
        XCTAssertFalse(next.elapse(4, token: old.id, visible: true))
        XCTAssertEqual(next.remaining, 4)
        XCTAssertTrue(next.elapse(4, token: next.id, visible: true))
    }
    func testWarningsDoNotDisappearOnSuccessTimer() {
        var warning = AppNotice("Копия не создана", kind: .warning)
        XCTAssertFalse(warning.elapse(500, token: warning.id, visible: true))
        XCTAssertEqual(warning.remaining, 4)
    }
}
