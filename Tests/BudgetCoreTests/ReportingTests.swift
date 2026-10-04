import XCTest
@testable import BudgetCore

final class ReportingTests: XCTestCase {
    func fixture() throws -> (Database, Account, BudgetCore.Category, Project) {
        var db = Database(); let a = Account(name: "Банк", currency: "RUB", openedOn: .today.firstOfMonth); let c = Category(name: "Еда", kind: .expense); let p = Project(name: "Ремонт")
        try Ledger.saveAccount(a, in: &db); try Ledger.saveCategory(c, in: &db); try Ledger.saveProject(p, in: &db); return (db, a, c, p)
    }
    func testAC11And12BothBudgetsAndExclusion() throws {
        var (db, a, c, p) = try fixture(); var monthly = Budget(kind: .monthly, name: "Месяц", currency: "RUB", start: .today.firstOfMonth); monthly.lines = [BudgetLine(categoryID: c.id, limit: 1_000_000)]; try Ledger.saveBudget(monthly, in: &db)
        var project = Budget(kind: .project, name: "Ремонт", currency: "RUB", start: .today.firstOfMonth); project.projectID = p.id; project.limit = 3_000_000; try Ledger.saveBudget(project, in: &db)
        var expense = Operation(kind: .expense, accountID: a.id, amount: 200_000); expense.categoryID = c.id; expense.projectID = p.id; try Ledger.saveOperation(expense, in: &db)
        XCTAssertEqual(try Reports.budgetFact(monthly, db: db).known, 200_000); XCTAssertEqual(try Reports.budgetFact(project, db: db).known, 200_000); XCTAssertEqual(try Reports.sum(db.operations, db: db, currency: "RUB").known, 200_000)
        expense.budgetMode = .excluded; try Ledger.saveOperation(expense, in: &db); XCTAssertEqual(try Reports.budgetFact(monthly, db: db).known, 0)
        expense.budgetMode = .automatic; try Ledger.saveOperation(expense, in: &db); db.budgets.removeAll { $0.id == monthly.id }; XCTAssertEqual(try db.balance(a.id), -200_000)
        var f = Filters(); f.participation = .outside; XCTAssertTrue(Reports.selected(db, filters: f, kinds: [.expense]).isEmpty); f.participation = .noMonthly; XCTAssertEqual(Reports.selected(db, filters: f, kinds: [.expense]).count, 1)
        try Ledger.validate(db)
    }
    func testAC13OverlapsAndZeroPlan() throws {
        var (db, _, c, p) = try fixture(); let child = Category(name: "Продукты", kind: .expense, parentID: c.id); try Ledger.saveCategory(child, in: &db)
        var b = Budget(kind: .monthly, name: "План", currency: "RUB", start: .today.firstOfMonth); b.lines = [BudgetLine(categoryID: c.id, limit: 0), BudgetLine(categoryID: child.id, limit: 100)]; XCTAssertThrowsError(try Ledger.saveBudget(b, in: &db))
        b.lines.removeLast(); try Ledger.saveBudget(b, in: &db); XCTAssertEqual(try b.plan, 0)
        var pb = Budget(kind: .project, name: "Первый", currency: "RUB", start: .today); pb.projectID = p.id; pb.limit = 1; try Ledger.saveBudget(pb, in: &db); pb.id = UUID(); pb.start = .today.adding(1); XCTAssertThrowsError(try Ledger.saveBudget(pb, in: &db))
    }
    func testAC14AC15SnapshotsAndPartial() throws {
        var db = Database(); let a = Account(name: "USD", currency: "USD"); try Ledger.saveAccount(a, opening: 2_000, in: &db)
        var o = Operation(kind: .expense, accountID: a.id, amount: 1_000); o.fx = [FXRate(base: "USD", quote: "RUB", rate: "90", date: .today)]; try Ledger.saveOperation(o, in: &db)
        db.rates = [FXRate(base: "USD", quote: "RUB", rate: "100", date: .today)]
        XCTAssertEqual(try Reports.sum(db.operations.filter { $0.kind == .expense }, db: db, currency: "RUB").known, 90_000); XCTAssertEqual(try Reports.total(Reports.balances(db, filters: Filters(), currency: "RUB")).known, 100_000)
        var tiny = Operation(kind: .expense, accountID: a.id, amount: 1); tiny.fx = [FXRate(base: "USD", quote: "RUB", rate: "1.5", date: .today)]; try Ledger.saveOperation(tiny, in: &db); XCTAssertEqual(try Reports.sum([tiny], db: db, currency: "RUB").known, 2)
        var missing = Operation(kind: .expense, accountID: a.id, amount: 1_000); try Ledger.saveOperation(missing, in: &db); missing = db.operations.last!; let v = try Reports.sum([o, missing], db: db, currency: "RUB"); XCTAssertEqual(v.known, 90_000); XCTAssertTrue(v.partial); XCTAssertEqual(v.missing, [missing.id])
    }
    func testAC16XMLAndInvalidNetwork() throws {
        let data = Data("<ValCurs Date=\"03.10.2026\"><Valute><CharCode>JPY</CharCode><Nominal>100</Nominal><Value>120,0000</Value></Valute><Valute><CharCode>USD</CharCode><Nominal>1</Nominal><Value>90,0000</Value></Valute></ValCurs>".utf8)
        let rates = try RateProvider.parseCBR(data, requested: try Day("2026-10-03")); XCTAssertEqual(rates.first { $0.base == "JPY" }?.rate, "1.2"); XCTAssertEqual(try Reports.rate(from: "USD", to: "JPY", rates: rates, on: try Day("2026-10-03")), "75")
        XCTAssertThrowsError(try RateProvider.parseCBR(Data("<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><x>&x;</x>".utf8)))
        XCTAssertThrowsError(try RateProvider.parseFrankfurter(Data("{\"date\":\"2099-01-01\",\"base\":\"USD\",\"quote\":\"RUB\",\"rate\":90}".utf8), base: "USD", quote: "RUB"))
    }
    func testAC18And19Reports() throws {
        var (db, _, _, _) = try fixture(); try Ledger.saveAccount(Account(name: "Йена", currency: "JPY"), in: &db)
        var r = Report(name: "Расходы по дням"); r.grouping = .day; r.presentation = .line; try Reports.validate(r, db: db)
        r.grouping = .category; XCTAssertThrowsError(try Reports.validate(r, db: db)); r.presentation = .ring; r.metric = .net; XCTAssertThrowsError(try Reports.validate(r, db: db))
        r.dataset = .balances; r.metric = .balance; XCTAssertThrowsError(try Reports.validate(r, db: db)); r.grouping = .account; r.presentation = .table; try Reports.validate(r, db: db)
        db.reports.append(r); db.dashboard[0].visible = false; db.dashboard.swapAt(0, 1); let restored = try JSONDecoder().decode(Database.self, from: JSONEncoder().encode(db)); XCTAssertEqual(restored.dashboard, db.dashboard); XCTAssertEqual(restored.reports, db.reports)
    }
}
