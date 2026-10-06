import XCTest
@testable import BudgetCore

final class ScheduledPaymentTests: XCTestCase {
    private func day(_ text: String) throws -> Day { try Day(text) }
    private func fixture(currency: String = "RUB", amount: Int64 = 2_500_000) throws -> (Database, ScheduledPayment, Account) {
        var db = Database(); let account = Account(name: "Вымышленный счёт", currency: currency, openedOn: try day("2024-01-01"))
        try Ledger.saveAccount(account, opening: 10_000_000, in: &db)
        var p = ScheduledPayment(title: "Оплата договора", comment: "Вымышленная поставка", amount: amount, currency: "RUB", dueOn: try day("2024-02-01")); p.accountID = account.id; p.timeZoneID = "Europe/Moscow"
        try ScheduledPayments.save(p, in: &db); return (db, p, account)
    }
    func testPlanningChangesNeitherFactsNorBalanceAndRequiresBothTexts() throws {
        var (db, p, account) = try fixture(); XCTAssertEqual(db.operations.count, 1); XCTAssertEqual(try db.balance(account.id), 10_000_000)
        for field in [0, 1] { for text in ["", " \n\t"] { var invalid = p; if field == 0 { invalid.title = text } else { invalid.comment = text }; let before = db; XCTAssertThrowsError(try ScheduledPayments.save(invalid, in: &db)); XCTAssertEqual(db, before) } }
        p.title = "  Название  "; p.comment = " Комментарий \n"; try ScheduledPayments.save(p, in: &db)
        XCTAssertEqual(db.financeData.scheduledPayments?.first?.title, "Название"); XCTAssertEqual(db.financeData.scheduledPayments?.first?.comment, "Комментарий")
    }
    func testInstallmentRoundingAnchorsAndAtomicInvalidRows() throws {
        var db = Database(); let p = ScheduledPayment(title: "Рассрочка", comment: "Договор", amount: 10_000, currency: "RUB", dueOn: try day("2024-01-31"))
        var rows = try ScheduledPayments.installments(template: p, count: 3)
        XCTAssertEqual(rows.map(\.amount), [3333, 3333, 3334]); XCTAssertEqual(rows.map { $0.dueOn.rawValue }, ["2024-01-31", "2024-02-29", "2024-03-31"])
        XCTAssertEqual(Set(rows.compactMap(\.planID)).count, 1)
        rows[1].comment = " "; let before = db; XCTAssertThrowsError(try ScheduledPayments.save(rows, in: &db)); XCTAssertEqual(db, before)
        var normal = p; normal.dueOn = try day("2025-01-31"); XCTAssertEqual(try ScheduledPayments.installments(template: normal, count: 3)[1].dueOn, try day("2025-02-28"))
        XCTAssertThrowsError(try ScheduledPayments.installments(template: p, count: 601))
        var edge = p; edge.dueOn = try day("9999-12-31"); XCTAssertThrowsError(try ScheduledPayments.installments(template: edge, count: 2, weekly: true))
    }
    func testPartialFullPaymentAndDuplicateProtection() throws {
        var (db, p, account) = try fixture(); _ = try ScheduledPayments.pay(p.id, from: account.id, amount: 1_000_000, date: day("2024-01-10"), in: &db)
        var current = try XCTUnwrap(db.financeData.scheduledPayments?.first)
        XCTAssertEqual(try ScheduledPayments.remaining(current, db: db), 1_500_000)
        let before = db; XCTAssertThrowsError(try ScheduledPayments.link(p.id, operationID: current.allocations[0].operationID, in: &db)); XCTAssertEqual(db, before)
        _ = try ScheduledPayments.pay(p.id, from: account.id, amount: 1_500_000, date: day("2024-01-20"), in: &db); current = try XCTUnwrap(db.financeData.scheduledPayments?.first)
        XCTAssertEqual(try ScheduledPayments.state(current, db: db), .paid); XCTAssertEqual(try db.balance(account.id), 7_500_000)
        XCTAssertTrue(db.operations.last?.comment.contains(p.title) == true); XCTAssertTrue(db.operations.last?.comment.contains(p.comment) == true)
        let closed = db; XCTAssertThrowsError(try ScheduledPayments.pay(p.id, from: account.id, amount: 100, in: &db)); XCTAssertEqual(db, closed)
    }
    func testSharedExistingExpenseAndEditsReconcileWithoutDuplication() throws {
        var (db, p, account) = try fixture(amount: 10_000); var other = p; other.id = UUID(); other.title = "Вторая позиция"; try ScheduledPayments.save(other, in: &db)
        var o = Operation(kind: .expense, date: try day("2024-01-10"), accountID: account.id, amount: 10_000); try Ledger.saveOperation(o, in: &db)
        try ScheduledPayments.link(p.id, operationID: o.id, sourceAmount: 4000, in: &db); try ScheduledPayments.link(other.id, operationID: o.id, sourceAmount: 6000, in: &db)
        XCTAssertEqual(db.operations.filter { $0.kind == .expense }.count, 1)
        let before = db; var third = p; third.id = UUID(); try ScheduledPayments.save(third, in: &db)
        XCTAssertThrowsError(try ScheduledPayments.link(third.id, operationID: o.id, in: &db)); ScheduledPayments.delete(third.id, in: &db); XCTAssertEqual(db, before)
        o.amount = 5000; try Ledger.saveOperation(o, in: &db)
        XCTAssertEqual(db.financeData.scheduledPayments?.map { $0.allocations.reduce(0) { $0 + $1.amount } }, [2000, 3000])
        try Ledger.deleteOperation(o.id, in: &db); XCTAssertTrue(db.financeData.scheduledPayments?.allSatisfy { $0.allocations.isEmpty } == true); try Ledger.validate(db)
    }
    func testDifferentCurrencyNeedsExplicitAmountsAndPreservesSnapshot() throws {
        var (db, p, account) = try fixture(currency: "USD", amount: 900_000); let before = db
        XCTAssertThrowsError(try ScheduledPayments.pay(p.id, from: account.id, amount: 10_000, date: day("2024-01-10"), in: &db)); XCTAssertEqual(db, before)
        let o = try ScheduledPayments.pay(p.id, from: account.id, amount: 10_000, paymentAmount: 900_000, date: day("2024-01-10"), in: &db)
        XCTAssertEqual(o.fx.first?.rate, "90"); XCTAssertEqual(try ScheduledPayments.remaining(db.financeData.scheduledPayments![0], db: db), 0)
    }
    func testClosingVarianceCancellationAndDeletionKeepExpense() throws {
        var (db, p, account) = try fixture(amount: 10_000)
        let o = try ScheduledPayments.pay(p.id, from: account.id, amount: 9000, date: day("2024-01-10"), closeRemainder: true, in: &db)
        var current = db.financeData.scheduledPayments![0]; XCTAssertEqual(current.amount, 9000); XCTAssertEqual(current.originalAmount, 10_000); XCTAssertEqual(try ScheduledPayments.state(current, db: db), .paid)
        current.cancelled = true; try ScheduledPayments.save(current, in: &db); ScheduledPayments.delete(p.id, in: &db)
        XCTAssertTrue(db.operations.contains { $0.id == o.id }); XCTAssertEqual(try db.balance(account.id), 9_991_000)
    }
    func testDueHistoryPreservesAbsoluteRemindersAndPaidGraph() throws {
        var (db, p, account) = try fixture(amount: 10_000); p.reminders.append(ScheduledPaymentReminder(date: try day("2024-01-20")))
        p.dueOn = try day("2024-03-01"); try ScheduledPayments.save(p, in: &db)
        let current = db.financeData.scheduledPayments![0]; XCTAssertEqual(current.dateHistory.last?.from, try day("2024-02-01")); XCTAssertEqual(current.reminders.last?.date, try day("2024-01-20"))
        _ = try ScheduledPayments.pay(p.id, from: account.id, amount: 10_000, date: day("2024-01-10"), in: &db)
        var paid = db.financeData.scheduledPayments![0]; paid.dueOn = try day("2024-04-01"); let before = db; XCTAssertThrowsError(try ScheduledPayments.save(paid, in: &db)); XCTAssertEqual(db, before)
    }
    func testTimezoneChangesOverdueAtLocalMidnight() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-01-01T23:30:00Z"))
        var p = ScheduledPayment(title: "Платёж", comment: "Комментарий", amount: 100, currency: "GBP", dueOn: try day("2024-01-01")); p.timeZoneID = "Europe/London"
        XCTAssertEqual(try ScheduledPayments.state(p, db: Database(), now: now), .today); p.timeZoneID = "Europe/Moscow"; XCTAssertEqual(try ScheduledPayments.state(p, db: Database(), now: now), .overdue)
    }
    func testMultipleReminderDeduplicationReschedulingAndGlobalCapacity() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-01-01T00:00:00Z"))
        var db = Database(); var p = ScheduledPayment(title: "Личное название", comment: "Личный комментарий", amount: 100, currency: "RUB", dueOn: try day("2024-01-10")); p.timeZoneID = "Europe/Moscow"
        p.reminders.append(p.reminders[1]); p.reminders[3].id = UUID(); try ScheduledPayments.save(p, in: &db); db.finances!.reminders.systemEnabled = true
        let first = try FinancialReminderPlanner.plan(db: db, events: FinancialEngine.events(db: db), now: now)
        XCTAssertEqual(first.count, 3); XCTAssertTrue(first.allSatisfy { !$0.id.contains(p.title) && !$0.databaseToken.contains(p.comment) })
        p.dueOn = try day("2024-01-11"); try ScheduledPayments.save(p, in: &db)
        let next = try FinancialReminderPlanner.plan(db: db, events: [], now: now); XCTAssertNotEqual(Set(first.map(\.id)), Set(next.map(\.id))); XCTAssertFalse(next.contains { $0.id == first[0].id })
        var payments: [ScheduledPayment] = []
        for i in 0..<65 { var q = p; q.id = UUID(); q.reminders = [ScheduledPaymentReminder(daysBefore: 0)]; q.reminders[0].hour = i / 60; q.reminders[0].minute = i % 60; payments.append(q) }
        try ScheduledPayments.save(payments, in: &db); let capped = try FinancialReminderPlanner.plan(db: db, events: [], now: now)
        XCTAssertEqual(capped.count, 60); XCTAssertEqual(Set(capped.map(\.id)).count, 60)
        db.finances!.scheduledPayments = [p]; var cancelled = p; cancelled.cancelled = true; try ScheduledPayments.save(cancelled, in: &db); XCTAssertTrue(try FinancialReminderPlanner.plan(db: db, events: [], now: now).isEmpty)
    }
    func testOldSchemaTwoDecodesAndMigrationBacksUpOriginal() throws {
        var old = Database(); old.version = 2; old.finances = FinancialBook()
        let encoded = try JSONEncoder().encode(old); let decoded = try JSONDecoder().decode(Database.self, from: encoded); XCTAssertNil(decoded.financeData.scheduledPayments)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scheduled-migration-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let key = try VaultCrypto.random(), store = VaultStore(url: root.appendingPathComponent("vault")); try store.initialize(db: old, dataKey: key, bootstrap: Bootstrap(databaseID: old.id, password: nil, recovery: Data())); store.close()
        let raw = try Data(contentsOf: store.url); store.beforeWrite = { throw BudgetError.storage("fixture failure") }; XCTAssertThrowsError(try store.unlock(key: key)); XCTAssertEqual(try Data(contentsOf: store.url), raw)
        store.beforeWrite = nil; try store.unlock(key: key); XCTAssertEqual(store.db?.version, 3)
        let originals = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Backups.noindex"), includingPropertiesForKeys: nil); XCTAssertFalse(originals.isEmpty)
        XCTAssertEqual(try VaultFile.read(Data(contentsOf: originals[0])).decrypt(key: key), old)
    }
    func testContractsAndScheduledPaymentsShareChronologicalLimitAndDST() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-03-25T00:00:00Z"))
        var db = Database(); let account = Account(name: "Депозит · тест", currency: "GBP", openedOn: try day("2024-03-01")); try Ledger.saveAccount(account, opening: 10_000, in: &db)
        var contract = FinancialContract(accountID: account.id, kind: .deposit, start: try day("2024-03-01"), end: try day("2024-04-01"), annualPercent: "12"); contract.timeZoneID = "Europe/London"; contract.reminders.interestEnabled = true; contract.reminders.paymentOffsets = [0]; contract.reminders.hour = 9
        try FinancialLedger.saveContract(contract, in: &db)
        var rows: [ScheduledPayment] = []
        for i in 0..<65 { var p = ScheduledPayment(title: "Позиция \(i)", comment: "Вымышленный договор", amount: 100, currency: "GBP", dueOn: try day("2024-03-31")); p.timeZoneID = "Europe/London"; p.reminders = [ScheduledPaymentReminder(daysBefore: 0)]; p.reminders[0].hour = 9; p.reminders[0].minute = i % 60; rows.append(p) }
        try ScheduledPayments.save(rows, in: &db); db.finances!.reminders.systemEnabled = true
        let event = FinanceEvent(id: "deposit-test", contractID: contract.id, kind: .depositInterest, date: try day("2024-03-26"), accrualEnd: try day("2024-03-26"), components: [], amount: 100, remaining: 100, balanceAfter: nil, accuracy: .calculated, notes: [])
        let queue = try FinancialReminderPlanner.plan(db: db, events: [event], now: now)
        XCTAssertEqual(queue.count, 60); XCTAssertEqual(queue.first?.eventToken, event.id)
        let dst = try XCTUnwrap(queue.first { $0.eventToken == rows[0].eventID }); XCTAssertEqual(ISO8601DateFormatter().string(from: dst.fireAt), "2024-03-31T08:00:00Z")
        let afterPayment = try ScheduledPayments.events(db: db); XCTAssertEqual(afterPayment.count, 65)
    }
    func testOverpaymentAndInvalidLinkedFactChangesAreAtomic() throws {
        var (db, p, account) = try fixture(amount: 10_000)
        var operation = try ScheduledPayments.pay(p.id, from: account.id, amount: 12_000, date: day("2024-01-10"), in: &db)
        XCTAssertEqual(try ScheduledPayments.paid(db.financeData.scheduledPayments![0], db: db), 12_000); XCTAssertEqual(db.financeData.scheduledPayments![0].amount, 10_000)
        let before = db; operation.kind = .income; XCTAssertThrowsError(try Ledger.saveOperation(operation, in: &db)); XCTAssertEqual(db, before)
        XCTAssertThrowsError(try Ledger.deleteAccount(account.id, in: &db)); XCTAssertEqual(db, before)
    }
    func testEncryptedCopyRoundTripAndCSVContainsOnlyPaidFacts() throws {
        var (db, p, account) = try fixture(); let key = try VaultCrypto.random(); let bootstrap = Bootstrap(databaseID: db.id, password: nil, recovery: Data())
        let raw = try VaultFile.make(db: db, key: key, bootstrap: bootstrap).encoded(); XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(p.comment))
        XCTAssertEqual(try VaultFile.read(raw).decrypt(key: key), db)
        let before = String(decoding: try CSVCodec.export(db.operations, db: db), as: UTF8.self); XCTAssertFalse(before.contains(p.comment))
        _ = try ScheduledPayments.pay(p.id, from: account.id, amount: 100_000, date: day("2024-01-10"), in: &db)
        XCTAssertTrue(String(decoding: try CSVCodec.export(db.operations, db: db), as: UTF8.self).contains(p.comment)); XCTAssertEqual(db.operations.filter { $0.kind == .expense }.count, 1)
    }
    func testPlanOnlyBudgetGetsSafetyCopyAndFullRestoreKeepsPaymentTextsAndLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScheduledRestore-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        var db = Database(); let p = ScheduledPayment(title: "Название договора", comment: "Обязательный комментарий", amount: 10_000, currency: "RUB", dueOn: Day.today.adding(7)); try ScheduledPayments.save(p, in: &db)
        let key = try VaultCrypto.random(), recovery = try VaultCrypto.random(), store = VaultStore(url: root.appendingPathComponent("source")); defer { store.close() }
        let bootstrap = Bootstrap(databaseID: db.id, password: try VaultCrypto.wrapPassword(key, password: "Fictional fixture password"), recovery: try VaultCrypto.seal(key, key: recovery, context: VaultCrypto.recoveryContext))
        try store.initialize(db: db, dataKey: key, bootstrap: bootstrap)
        let safety = try XCTUnwrap(Backups.beforeMassChange(store: store, folder: root.appendingPathComponent("copies")))
        XCTAssertEqual(try VaultFile.read(Data(contentsOf: safety)).decrypt(key: key).financeData.scheduledPayments?.first?.comment, p.comment)
        let account = Account(name: "Вымышленный счёт", currency: "RUB")
        try store.transaction { try Ledger.saveAccount(account, opening: 100_000, in: &$0); _ = try ScheduledPayments.pay(p.id, from: account.id, amount: 4000, in: &$0) }
        let copy = try Backups.write(store: store, folder: root.appendingPathComponent("copies"), kind: "service")
        let target = VaultStore(url: root.appendingPathComponent("restored")); defer { target.close() }
        let checked = try target.previewRestore(from: copy, recovery: VaultCrypto.recoveryString(recovery))
        try target.restore(database: checked.0, dataKey: checked.2, bootstrap: checked.1.bootstrap, safetyCopy: nil)
        let restored = try XCTUnwrap(target.db?.financeData.scheduledPayments?.first)
        XCTAssertEqual(restored.title, p.title); XCTAssertEqual(restored.comment, p.comment); XCTAssertEqual(restored.reminders, p.reminders); XCTAssertEqual(restored.allocations.count, 1); XCTAssertEqual(try ScheduledPayments.remaining(restored, db: target.db!), 6000)
    }
}
