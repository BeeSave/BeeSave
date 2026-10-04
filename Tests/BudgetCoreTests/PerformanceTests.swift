import XCTest
@testable import BudgetCore

final class PerformanceTests: XCTestCase {
    func testAC30Volume() throws {
        guard ProcessInfo.processInfo.environment["BEESAVE_PERF"] == "1" else { throw XCTSkip("Run with BEESAVE_PERF=1 in Release") }
        var db = Database(); let day = Day.today; let start = day.firstOfMonth
        db.accounts = (0..<100).map { Account(name: "Счёт \($0)", currency: "RUB", openedOn: start) }
        db.categories += (0..<498).map { BudgetCore.Category(name: "Категория \($0)", kind: .expense) }
        db.projects = (0..<100).map { Project(name: "Проект \($0)") }
        db.reports = (0..<100).map { var r = Report(name: "Отчёт \($0)"); r.grouping = .category; return r }
        var monthly = Budget(kind: .monthly, name: "Месяц", currency: "RUB", start: start); monthly.lines = [BudgetLine(categoryID: db.categories[2].id, limit: 10_000_000)]
        var project = Budget(kind: .project, name: "Проект", currency: "RUB", start: start); project.projectID = db.projects[0].id; project.limit = 10_000_000
        db.budgets = [monthly, project]; db.settings.lastDaily = .today
        db.operations.reserveCapacity(100_000)
        for i in 0..<100_000 { var o = Operation(kind: i % 5 == 0 ? .income : .expense, date: day, accountID: db.accounts[i % 100].id, amount: Int64(1 + i % 10_000)); o.categoryID = o.kind == .income ? db.categories[1].id : db.categories[2 + i % 498].id; o.projectID = db.projects[i % 100].id; o.comment = "Тест \(i)"; db.operations.append(o) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); let store = VaultStore(url: root.appendingPathComponent("data.beesave")); defer { store.close(); try? FileManager.default.removeItem(at: root) }
        let key = try VaultCrypto.random(); let recovery = try VaultCrypto.random(); let b = Bootstrap(databaseID: db.id, password: nil, recovery: try VaultCrypto.seal(key, key: recovery, context: VaultCrypto.recoveryContext)); try store.initialize(db: db, dataKey: key, bootstrap: b)
        func dashboardRows() throws {
            var r = Report(name: "Потоки"); r.filters = .month; r.grouping = .month
            for metric in [Metric.income, .expense, .net] { r.metric = metric; _ = try Reports.rows(r, db: db) }
            r.grouping = .day; r.presentation = .line; for metric in [Metric.income, .expense] { r.metric = metric; _ = try Reports.rows(r, db: db) }
            r.metric = .expense; r.presentation = .table; r.grouping = .category; _ = try Reports.rows(r, db: db)
            _ = try Reports.balances(db, filters: .month, currency: "RUB")
            _ = try Reports.budgetFact(monthly, db: db, filters: .month); _ = try Reports.budgetFact(project, db: db, filters: .month)
            r.grouping = .project; _ = try Reports.rows(r, db: db)
            r.grouping = .category; r.filters.participation = .outside; _ = try Reports.rows(r, db: db)
        }
        try dashboardRows(); let t = Date(); try dashboardRows(); let dashboard = Date().timeIntervalSince(t)
        let s = Date(); try store.transaction { db in try Ledger.saveOperation(Operation(kind: .expense, accountID: db.accounts[0].id, amount: 100), in: &db) }; let save = Date().timeIntervalSince(s)
        let csv = Data(("date,type,account_name,amount,comment\n" + (0..<100_000).map { "\(day),expense,Счёт 0,1,Импорт \($0)\n" }.joined()).utf8)
        var empty = db; empty.operations = []; let importStore = VaultStore(url: root.appendingPathComponent("import.beesave")); defer { importStore.close() }; try importStore.initialize(db: empty, dataKey: key, bootstrap: b)
        let beforeImport = Date(); var progressEvents = 0; let p = try CSVImporter.preview(data: csv, options: ImportOptions(), db: empty, progress: { _ in progressEvents += 1 }); _ = try Backups.beforeMassChange(store: importStore, folder: root.appendingPathComponent("backups")); try importStore.transaction { try CSVImporter.commit(p, into: &$0) }; let imported = Date().timeIntervalSince(beforeImport)
        print("PERFORMANCE dashboard=\(dashboard)s save=\(save)s import100k=\(imported)s ciphertext=\((try Data(contentsOf: store.url)).count)bytes")
        XCTAssertLessThanOrEqual(dashboard, 2); XCTAssertLessThanOrEqual(save, 1); XCTAssertLessThanOrEqual(imported, 60); XCTAssertEqual(p.added.count, 100_000)
        XCTAssertEqual(importStore.db?.operations.count, 100_000); XCTAssertGreaterThan(progressEvents, 1)
    }
}
