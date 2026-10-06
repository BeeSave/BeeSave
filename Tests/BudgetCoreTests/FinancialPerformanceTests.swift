import XCTest
@testable import BudgetCore

final class FinancialPerformanceTests: XCTestCase {
    func testScheduledPlansWithLargeOperationHistory() throws {
        guard ProcessInfo.processInfo.environment["BEESAVE_FINANCE_PERF"] == "1" else { throw XCTSkip("Run the scheduled payment volume check in an optimized build.") }
        var db = Database(); let account = Account(name: "Scheduled volume fixture", currency: "RUB", openedOn: Day.today.adding(-1)); try Ledger.saveAccount(account, opening: 100_000_000, in: &db)
        db.operations += (0..<99_999).map { _ in var o = Operation(kind: .expense, accountID: account.id, amount: 1); o.categoryID = db.categories.first { $0.kind == .expense }!.id; return o }
        var template = ScheduledPayment(title: "Fictional instalments", comment: "Volume fixture only", amount: 60_000, currency: "RUB", dueOn: Day.today.adding(1)); template.accountID = account.id
        try ScheduledPayments.save(ScheduledPayments.installments(template: template, count: 600, weekly: true), in: &db); db.finances!.reminders.systemEnabled = true
        let began = Date(); let events = try ScheduledPayments.events(db: db), queue = try FinancialReminderPlanner.plan(db: db, events: [], limit: 60)
        let seconds = Date().timeIntervalSince(began); XCTAssertEqual(events.count, 600); XCTAssertFalse(queue.isEmpty); XCTAssertLessThanOrEqual(seconds, 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScheduledVolume-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let key = try VaultCrypto.random(), store = VaultStore(url: root.appendingPathComponent("vault")); defer { store.close() }
        try store.initialize(db: db, dataKey: key, bootstrap: Bootstrap(databaseID: db.id, password: nil, recovery: Data()))
        let id = db.financeData.scheduledPayments![0].id, paymentBegan = Date()
        try store.transaction { _ = try ScheduledPayments.pay(id, from: account.id, amount: 100, in: &$0) }
        let paidSeconds = Date().timeIntervalSince(paymentBegan); XCTAssertLessThanOrEqual(paidSeconds, 1)
        print("SCHEDULED_PERF operations=100000 plans=600 forecast=\(seconds)s encrypted_payment=\(paidSeconds)s")
    }
    func testLargeFinancialForecastAndConfirmation() throws {
        guard ProcessInfo.processInfo.environment["BEESAVE_FINANCE_PERF"] == "1" else { throw XCTSkip("Run the financial volume check in an optimized build.") }
        var db = Database(); let start = try FinanceMath.addingMonths(Day.today.firstOfMonth, -1)
        for index in 0..<100 {
            let kind: AccountKind = index < 25 ? .deposit : index < 50 ? .revolvingCredit : index < 75 ? .termLoan : .mortgage
            var account = Account(name: "Счёт \(index)", currency: "RUB", openedOn: start); account.financialKind = kind
            let duration = kind == .deposit ? 12 : 600
            var contract = FinancialContract(accountID: account.id, kind: kind, start: start, end: kind == .revolvingCredit ? nil : try FinanceMath.addingMonths(start, duration), annualPercent: "12")
            contract.originalPrincipal = 300_000_000; contract.terms[0].basis = .equalMonths; account.contractID = contract.id
            db.accounts.append(account); var book = db.financeData; book.contracts.append(contract); db.finances = book
            var opening = Operation(kind: .opening, date: start, accountID: account.id, amount: kind.isDebt ? -300_000_000 : 300_000_000); opening.createdAt = Date(timeIntervalSince1970: 0); db.operations.append(opening)
        }
        for index in 0..<99_900 {
            var operation = Operation(kind: .expense, date: start.adding(1 + index % 20), accountID: db.accounts[index % 100].id, amount: 1)
            operation.categoryID = db.categories.first { $0.kind == .expense }!.id; db.operations.append(operation)
        }
        try Ledger.validate(db)
        _ = try FinancialEngine.events(contract: db.financeData.contracts[50], db: db)
        let began = Date(); let events = try FinancialEngine.events(db: db)
        let operations = FinancialLedger.operationsByAccount(in: db)
        for contract in db.financeData.contracts where contract.kind.isDebt { var projection = db; projection.operations = operations[contract.accountID] ?? []; _ = try FinancialLedger.debt(accountID: contract.accountID, db: projection) }
        let forecastSeconds = Date().timeIntervalSince(began)
        XCTAssertGreaterThanOrEqual(events.count, 30_000)
        print("FINANCE_PERF operations=\(db.operations.count) accounts=\(db.accounts.count) contracts=\(db.financeData.contracts.count) rows=\(events.count) forecast_seconds=\(forecastSeconds)")
        XCTAssertLessThanOrEqual(forecastSeconds, 5)
        let contract = db.financeData.contracts[50]
        let saveBegan = Date()
        try FinancialLedger.payDebt(contractID: contract.id, from: db.accounts[0].id, amount: 3_000_000, interestCharge: 2_000_000, date: .today, in: &db)
        let confirmationSeconds = Date().timeIntervalSince(saveBegan)
        print("FINANCE_PERF ledger_confirmation_seconds=\(confirmationSeconds)")
        XCTAssertLessThanOrEqual(confirmationSeconds, 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinanceVolume-" + UUID().uuidString + ".noindex")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultStore(url: root.appendingPathComponent("vault.beesave")); defer { store.close() }
        let key = try VaultCrypto.random(), recovery = try VaultCrypto.random()
        let bootstrap = Bootstrap(databaseID: db.id, password: nil, recovery: try VaultCrypto.seal(key, key: recovery, context: VaultCrypto.recoveryContext))
        try store.initialize(db: db, dataKey: key, bootstrap: bootstrap)
        let expectedBefore = try FinancialLedger.debt(accountID: contract.accountID, db: db).debt
        let persistedBegan = Date()
        try store.transaction { candidate in try FinancialLedger.payDebt(contractID: contract.id, from: db.accounts[0].id, amount: 100_000, date: .today, in: &candidate) }
        let persistedSeconds = Date().timeIntervalSince(persistedBegan)
        print("FINANCE_PERF vault_confirmation_seconds=\(persistedSeconds) target_seconds=1")
        XCTAssertLessThanOrEqual(persistedSeconds, 1)
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: store.db!).debt, expectedBefore - 100_000)
        // FAC-21 additionally requires measuring the UI update; this check covers encrypted persistence.
    }
}
