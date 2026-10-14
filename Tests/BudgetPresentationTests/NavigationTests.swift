import XCTest
import BudgetCore
@testable import BudgetPresentation

final class NavigationTests: XCTestCase {
    func testSourceReturnPreservesDistinctContexts() {
        var navigation = NavigationState()
        let calendar = WorkspaceRoute(.plan), project = WorkspaceRoute(.projects, project: .payments, objectID: UUID())
        navigation.go(to: calendar)
        navigation.updateContext(for: calendar) { $0.search = "Договор"; $0.scrollOffset = 415; $0.filters.accounts = [UUID()] }
        let original = navigation.context(for: calendar)
        navigation.go(to: project); navigation.updateContext(for: project) { $0.search = "Аванс" }
        navigation.back()
        XCTAssertEqual(navigation.current, calendar); XCTAssertEqual(navigation.context(for: calendar), original)
        XCTAssertEqual(navigation.context(for: project).search, "Аванс")
    }
    func testJournalOuterAndTablePositionsRemainIndependent() {
        var navigation = NavigationState()
        let journal = WorkspaceRoute(.operations)
        navigation.go(to: journal)
        navigation.updateContext(for: journal) { $0.scrollOffset = 680; $0.tableScrollOffset = 2460; $0.tableScrollX = 440; $0.journal = .transfers }
        navigation.go(to: WorkspaceRoute(.accounts))
        navigation.back()
        let restored = navigation.context(for: journal)
        XCTAssertEqual(restored.scrollOffset, 680)
        XCTAssertEqual(restored.tableScrollOffset, 2460)
        XCTAssertEqual(restored.tableScrollX, 440)
        XCTAssertEqual(restored.journal, .transfers)
    }
    func testRepeatingRouteDoesNotAddHistoryAndLockClearsPrivateState() {
        var navigation = NavigationState(); let account = WorkspaceRoute(.accounts, objectID: UUID())
        navigation.go(to: account); navigation.go(to: account)
        XCTAssertEqual(navigation.history.count, 1)
        navigation.updateContext(for: account) { $0.search = "Личные накопления"; $0.selectedID = UUID() }
        navigation.clear()
        XCTAssertEqual(navigation.current, WorkspaceRoute(.overview)); XCTAssertFalse(navigation.canGoBack); XCTAssertTrue(navigation.contexts.isEmpty)
    }
    func testViewsDoNotMergeAccountOrProjectContextAndHistoryIsBounded() {
        var navigation = NavigationState()
        let a = WorkspaceRoute(.accounts, objectID: UUID()), b = WorkspaceRoute(.accounts, objectID: UUID())
        navigation.updateContext(for: a) { $0.filters.search = "USD" }
        XCTAssertEqual(navigation.context(for: b).filters.search, "")
        for _ in 0..<150 { navigation.go(to: WorkspaceRoute(.projects, objectID: UUID())) }
        XCTAssertEqual(navigation.history.count, 100)
        XCTAssertEqual(JournalSelection.transfers.kind, .transfer); XCTAssertEqual(JournalSelection.opening.kind, .opening)
    }
    func testCalendarSourcesReturnToTheirOwnFilters() throws {
        var navigation = NavigationState()
        let all = WorkspaceRoute(.plan), contracts = WorkspaceRoute(.plan, calendar: .contracts), scheduled = WorkspaceRoute(.plan, calendar: .scheduled)
        let start = try Day("2026-10-01")
        navigation.go(to: all)
        navigation.updateContext(for: all) { $0.calendarConditional = true; $0.filters.start = start; $0.scrollOffset = 850 }
        navigation.go(to: contracts)
        navigation.updateContext(for: contracts) { $0.includeFulfilled = true; $0.bankID = "fictional-bank"; $0.scrollOffset = 210 }
        navigation.go(to: scheduled)
        navigation.updateContext(for: scheduled) { $0.scheduledStatus = "Все"; $0.scheduledFrom = "2026-11-01" }
        navigation.back()
        XCTAssertEqual(navigation.current, contracts)
        XCTAssertTrue(navigation.context(for: contracts).includeFulfilled)
        XCTAssertEqual(navigation.context(for: contracts).scrollOffset, 210)
        navigation.back()
        XCTAssertEqual(navigation.current, all)
        XCTAssertTrue(navigation.context(for: all).calendarConditional)
        XCTAssertEqual(navigation.context(for: all).scrollOffset, 850)
        XCTAssertEqual(navigation.context(for: scheduled).scheduledStatus, "Все")
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceRoute.self, from: JSONEncoder().encode(contracts)), contracts)
    }
}
