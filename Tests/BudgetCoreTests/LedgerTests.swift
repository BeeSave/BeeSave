import XCTest
@testable import BudgetCore

final class LedgerTests: XCTestCase {
    func testLongAmountsCannotLoseFractionsAndISODateIsStrict() throws {
        XCTAssertThrowsError(try Money.parse("1.0000000000000000000000000000000000000000001", currency: "RUB"))
        XCTAssertEqual(try Money.parse("1.0000000000000000000000000000000000000000000", currency: "RUB"), 100)
        XCTAssertThrowsError(try Day("+123-01-01")); XCTAssertThrowsError(try Day("2026-+1-01"))
        XCTAssertEqual(Money.string(Int64.min, currency: "RUB"), "-92233720368547758.08")
    }
    func setup(_ balance: Int64 = 100_000) throws -> (Database, Account) { var db = Database(); let a = Account(name: "Наличные", currency: "RUB", openedOn: Day.today.adding(-30)); try Ledger.saveAccount(a, opening: balance, in: &db); return (db, a) }
    func testAC02And03EditDelete() throws {
        var (db, a) = try setup(); var income = Operation(kind: .income, accountID: a.id, amount: 50_000); try Ledger.saveOperation(income, in: &db); income = db.operations.last!
        var expense = Operation(kind: .expense, accountID: a.id, amount: 20_000); try Ledger.saveOperation(expense, in: &db); expense = db.operations.last!
        XCTAssertEqual(try db.balance(a.id), 130_000); XCTAssertEqual(try Reports.sum(db.operations.filter { $0.kind == .income }, db: db, currency: "RUB").known, 50_000)
        expense.amount = 30_000; try Ledger.saveOperation(expense, in: &db); XCTAssertEqual(try db.balance(a.id), 120_000)
        try Ledger.deleteOperation(expense.id, in: &db); XCTAssertEqual(try db.balance(a.id), 150_000); try Ledger.deleteOperation(income.id, in: &db); XCTAssertEqual(try db.balance(a.id), 100_000); try Ledger.validate(db)
    }
    func testAC04NegativeAllowedAndAC10Unbudgeted() throws {
        var (db, a) = try setup(); let o = Operation(kind: .expense, accountID: a.id, amount: 110_000); try Ledger.saveOperation(o, in: &db)
        XCTAssertEqual(try db.balance(a.id), -10_000); XCTAssertTrue(db.operations.last!.categoryID != nil); var f = Filters(); f.participation = .outside; XCTAssertTrue(Reports.selected(db, filters: f, kinds: [.expense]).contains { $0.id == o.id })
    }
    func testAC05And06Transfers() throws {
        var (db, a) = try setup(1_000_000); let usd = Account(name: "USD", currency: "USD", openedOn: a.openedOn); let rub = Account(name: "Банк", currency: "RUB", openedOn: a.openedOn)
        try Ledger.saveAccount(usd, in: &db); try Ledger.saveAccount(rub, in: &db)
        var t = Operation(kind: .transfer, accountID: a.id, amount: 900_000); t.toAccountID = usd.id; t.toAmount = 10_000; try Ledger.saveOperation(t, in: &db)
        XCTAssertEqual(try db.balance(a.id), 100_000); XCTAssertEqual(try db.balance(usd.id), 10_000); XCTAssertEqual(db.operations.last!.transferRate, "0.011111111111111111111111111111111111111")
        t = Operation(kind: .transfer, accountID: a.id, amount: 10_000); t.toAccountID = rub.id; t.toAmount = 10_000; try Ledger.saveOperation(t, in: &db); XCTAssertEqual(try db.balance(a.id) + db.balance(rub.id), 100_000)
        XCTAssertTrue(db.operations.filter { $0.kind.isFlow }.isEmpty); try Ledger.validate(db)
    }
    func testAC08FixedDelta() throws {
        var (db, a) = try setup(); let adj = try Ledger.reconcile(accountID: a.id, observed: 95_000, reason: "Сверка", in: &db)!
        XCTAssertEqual(adj.amount, -5_000); var o = Operation(kind: .expense, date: Day.today.adding(-1), accountID: a.id, amount: 2_000); try Ledger.saveOperation(o, in: &db); o = db.operations.last!
        XCTAssertEqual(try db.balance(a.id), 93_000); XCTAssertEqual(db.operations.first { $0.id == adj.id }?.amount, -5_000); XCTAssertNil(try Ledger.reconcile(accountID: a.id, observed: 93_000, reason: "Совпало", in: &db)); try Ledger.validate(db)
    }
    func testAC09ArchiveAndReferences() throws {
        var (db, a) = try setup(); var archive = a; archive.archived = true; try Ledger.saveAccount(archive, in: &db)
        XCTAssertThrowsError(try Ledger.saveOperation(Operation(kind: .expense, accountID: a.id, amount: 10), in: &db)); XCTAssertThrowsError(try Ledger.deleteAccount(a.id, in: &db)); XCTAssertEqual(try Reports.total(Reports.balances(db, filters: Filters(), currency: "RUB")).known, 100_000)
        archive.archived = false; try Ledger.saveAccount(archive, in: &db); try Ledger.saveOperation(Operation(kind: .expense, accountID: a.id, amount: 10), in: &db)
    }
    func testCurrencyDateCategoryConstraintsAndOverflow() throws {
        var (db, a) = try setup(); var changed = a; changed.currency = "USD"; XCTAssertThrowsError(try Ledger.saveAccount(changed, in: &db))
        XCTAssertThrowsError(try Ledger.saveAccount(Account(name: "  НАЛИЧНЫЕ ", currency: "RUB"), in: &db))
        XCTAssertThrowsError(try Ledger.saveOperation(Operation(kind: .income, date: .today.adding(1), accountID: a.id, amount: 1), in: &db))
        XCTAssertThrowsError(try Money.add(Int64.max, 1)); XCTAssertThrowsError(try Money.parse("0.001", currency: "USD")); XCTAssertThrowsError(try Day("2026-02-30"))
        let oldDate = try Day("2026-02-01"); XCTAssertEqual(oldDate.month, "2026-02"); XCTAssertEqual(oldDate.lastOfMonth.rawValue, "2026-02-28")
    }
    func testHalfUpAC15() throws { XCTAssertEqual(try Money.convert(1, from: "USD", to: "RUB", rate: "1.5"), 2); XCTAssertEqual(try Money.parse("12.345", currency: "KWD"), 12_345); XCTAssertEqual(try Money.parse("12", currency: "JPY"), 12) }
}
