import XCTest
import BudgetCore
@testable import BudgetPresentation

final class UIStateTests: XCTestCase {
    func testRangeSelectionIsDraftAndNormalizesAcrossYear() throws {
        let original = Filters(start: try Day("2026-10-01"), end: try Day("2026-10-04"))
        var draft = DateRangeDraft(start: original.start, end: original.end)
        draft.select(try Day("2027-01-03")); XCTAssertThrowsError(try draft.apply(to: original))
        draft.select(try Day("2026-12-30"))
        XCTAssertEqual(original.end, try Day("2026-10-04"))
        let result = try draft.apply(to: original)
        XCTAssertEqual(result.start, try Day("2026-12-30")); XCTAssertEqual(result.end, try Day("2027-01-03"))
        draft.select(try Day("2024-02-29")); draft.select(try Day("2024-02-29"))
        XCTAssertEqual(try draft.apply(to: original).start, try draft.apply(to: original).end)
    }
    func testPresetsAndCalendarUseCalendarDays() throws {
        let today = try Day("2024-03-03"); var draft = DateRangeDraft(start: nil, end: nil)
        draft.preset(.previous, today: today); XCTAssertEqual(draft.end, try Day("2024-02-29")); XCTAssertEqual(draft.start, try Day("2024-02-01"))
        draft.preset(.all, today: today); XCTAssertNil(draft.start); XCTAssertNil(draft.end)
        let cells = CalendarDays.cells(try Day("2026-10-01")); XCTAssertNil(cells[2]); XCTAssertEqual(cells[3], try Day("2026-10-01")); XCTAssertEqual(cells.compactMap { $0 }.count, 31)
        for offset in [-43200, 10800, 50400] {
            let zone = TimeZone(secondsFromGMT: offset)!, day = try Day("2024-02-29")
            XCTAssertEqual(CalendarDays.day(CalendarDays.localDate(day, timeZone: zone), timeZone: zone), day)
        }
    }
    func testResetCancelAndApplyPreserveHistoryContext() throws {
        var db = Database(); let a = Account(name: "A", currency: "RUB"), b = Account(name: "B", currency: "USD"); db.accounts = [a,b]
        var filters = Filters(); filters.accounts = [a.id]; filters.currency = "USD"; filters.includeArchived = false
        var draft = FilterDraft(filters); draft.reset(today: try Day("2026-10-04"), fixedAccount: a.id)
        XCTAssertEqual(draft.original, filters); XCTAssertEqual(filters.currency, "USD")
        draft.value.accounts = [b.id]
        let result = try draft.apply(database: db, fixedAccount: a.id)
        XCTAssertEqual(result.accounts, [a.id]); XCTAssertNil(result.currency); XCTAssertEqual(result.start, try Day("2026-10-01"))
    }
    func testPreferredAccountAndReportTransitionDoNotMutateOriginal() throws {
        var db = Database(); let a = Account(name: "A", currency: "RUB"), b = Account(name: "B", currency: "RUB"); db.accounts = [a,b]
        XCTAssertNil(EditorContext.account(in: db, kind: .expense))
        db.operations = [Operation(kind: .expense, accountID: b.id, amount: 100)]
        XCTAssertEqual(EditorContext.account(in: db, kind: .expense), b.id); XCTAssertEqual(EditorContext.account(in: db, kind: .expense, context: a.id), a.id)
        var report = Report(name: "Пример"); report.filters.projectID = UUID(); report.filters.categories = [UUID()]; report.filters.participation = .outside
        let (next, removed) = EditorContext.changingDataset(report, to: .balances)
        XCTAssertEqual(removed.count, 4); XCTAssertNotNil(report.filters.projectID); XCTAssertNil(next.filters.projectID); XCTAssertEqual(next.metric, .balance)
    }
    func testFixturesKeepExactTotalsAndPartialValuation() throws {
        let day = try Day("2026-10-05")
        let db = try PreviewFixtures.database(.filled, today: day)
        let balances = try Reports.total(Reports.balances(db, filters: .month, currency: "RUB", day: day))
        XCTAssertEqual(balances.known, 5_317_000); XCTAssertFalse(balances.partial)
        let expenses = Reports.selected(db, filters: Filters(start: day.firstOfMonth, end: day), kinds: [.expense])
        XCTAssertEqual(try Reports.sum(expenses, db: db, currency: "RUB").known, 128_000)
        XCTAssertEqual(try Reports.budgetFact(db.budgets[0], db: db).known, 128_000)
        let partial = try PreviewFixtures.database(.partial, today: day)
        let value = try Reports.sum(Reports.selected(partial, filters: Filters(), kinds: [.expense]), db: partial, currency: "RUB")
        XCTAssertEqual(value.known, 128_000); XCTAssertEqual(value.missing.count, 1); XCTAssertEqual(value.currencies, ["USD"])
    }
    func testExistingLayoutAndFilterSelectionSurviveRoundTrip() throws {
        let db = try PreviewFixtures.database(.custom, today: Day("2026-10-05"))
        let decoded = try JSONDecoder().decode(Database.self, from: JSONEncoder().encode(db))
        XCTAssertEqual(decoded, db); XCTAssertTrue(decoded.dashboard[1].wide)
        XCTAssertNotNil(decoded.dashboard[1].ownFilters); XCTAssertFalse(decoded.dashboard[2].visible)
        XCTAssertTrue(DashboardBlock.defaults.allSatisfy { !$0.wide })
        var filters = Filters(); filters.search = "покупки"; filters.categories = [db.categories.first { $0.name == "Продукты" }!.id]
        XCTAssertEqual(Reports.selected(db, filters: filters, kinds: [.expense]).count, 1)
        var draft = FilterDraft(filters); draft.reset(today: try Day("2026-10-05"), period: Filters())
        XCTAssertNil(draft.value.start); XCTAssertEqual(draft.original.search, "покупки")
    }
    func testHistoryProjectionUsesPostingCurrencyAndSignedAmount() {
        let source = Account(name: "RUB", currency: "RUB"), destination = Account(name: "USD", currency: "USD")
        var transfer = Operation(kind: .transfer, accountID: source.id, amount: 10_000); transfer.toAccountID = destination.id; transfer.toAmount = 110
        let debit = OperationTableEntry(operation: transfer, source: source, context: source)
        let credit = OperationTableEntry(operation: transfer, source: source, context: destination)
        XCTAssertEqual(debit.amount, -10_000); XCTAssertEqual(debit.currency, "RUB")
        XCTAssertEqual(credit.amount, 110); XCTAssertEqual(credit.currency, "USD")
        XCTAssertEqual(OperationTableEntry(operation: transfer, source: source).amount, 10_000)
    }
    func testReadableMoneyKeepsMinorUnitsAndRatePrecision() throws {
        func compact(_ value: String) -> String { value.filter { !$0.isWhitespace } }
        XCTAssertEqual(compact(DisplayFormat.money(5_317_000, currency: "RUB")), "53170,00RUB")
        XCTAssertEqual(compact(DisplayFormat.money(Int64.min, currency: "RUB")), "-92233720368547758,08RUB")
        XCTAssertEqual(compact(DisplayFormat.money(123, currency: "JPY")), "123JPY")
        XCTAssertEqual(compact(DisplayFormat.money(1, currency: "KWD")), "0,001KWD")
        let ratio = try Money.ratio(from: 92_000, currency: "RUB", to: 1_000, toCurrency: "USD")
        XCTAssertEqual(DisplayFormat.rate(ratio), "0,010869565")
        XCTAssertEqual(DisplayFormat.rate("0.00000000123"), "0,00000000123")
    }
}
