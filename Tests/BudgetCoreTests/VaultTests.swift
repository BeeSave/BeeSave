import XCTest
@testable import BudgetCore

final class VaultTests: XCTestCase {
    let password = "Тестовая длинная фраза 🔐"
    func fixture() throws -> (URL, VaultStore, Data, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true); let url = root.appendingPathComponent("vault.beesave")
        let store = VaultStore(url: url); var db = Database(); try Ledger.saveAccount(Account(name: "Секретный счёт 987654", currency: "RUB"), opening: 100_000, in: &db)
        let key = try VaultCrypto.random(); let recovery = try VaultCrypto.random(); let b = Bootstrap(databaseID: db.id, password: try VaultCrypto.wrapPassword(key, password: password), recovery: try VaultCrypto.seal(key, key: recovery, context: VaultCrypto.recoveryContext))
        try store.initialize(db: db, dataKey: key, bootstrap: b); return (root, store, key, VaultCrypto.recoveryString(recovery))
    }
    func testArgon2DeterministicDerivation() throws {
        var e = KeyEnvelope(salt: Data("somesalt".utf8) + Data(repeating: 0, count: 8), sealed: Data()); e.memory = 19_456; e.passes = 2
        let a = try VaultCrypto.derive(password: "пароль", envelope: e); let b = try VaultCrypto.derive(password: "пароль", envelope: e)
        XCTAssertEqual(a, b); XCTAssertNotEqual(a, try VaultCrypto.derive(password: "пароль2", envelope: e)); XCTAssertEqual(a.count, 32)
    }
    func testAC23AC26CiphertextAndUnlock() throws {
        let (root, store, _, recovery) = try fixture(); defer { store.close(); try? FileManager.default.removeItem(at: root) }
        let data = try Data(contentsOf: store.url); XCTAssertNil(data.range(of: Data("Секретный счёт 987654".utf8))); XCTAssertNil(data.range(of: Data(password.utf8))); XCTAssertFalse(data.starts(with: Data("SQLite format 3".utf8)))
        store.close(); XCTAssertThrowsError(try store.unlock(password: "неверный пароль")); XCTAssertNil(store.db); try store.unlock(password: password); XCTAssertEqual(store.db!.accounts.count, 1)
        store.close(); try store.unlock(recovery: recovery); XCTAssertEqual(store.db!.accounts.count, 1)
        XCTAssertThrowsError(try VaultCrypto.recoveryKey(recovery + "A"))
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".encrypted") })
    }
    func testAC07AtomicTransferFailure() throws {
        let (root, store, key, _) = try fixture(); defer { store.close(); try? FileManager.default.removeItem(at: root) }
        try store.transaction { db in try Ledger.saveAccount(Account(name: "Второй", currency: "RUB"), in: &db) }
        let before = store.db!; let bytes = try Data(contentsOf: store.url)
        store.beforeWrite = { throw BudgetError.storage("Injected") }
        XCTAssertThrowsError(try store.transaction { db in var t = Operation(kind: .transfer, accountID: db.accounts[0].id, amount: 100); t.toAccountID = db.accounts[1].id; t.toAmount = 100; try Ledger.saveOperation(t, in: &db) })
        XCTAssertEqual(store.db, before); XCTAssertEqual(try Data(contentsOf: store.url), bytes); store.beforeWrite = nil
        var transfer = Operation(kind: .transfer, accountID: before.accounts[0].id, amount: 100); transfer.toAccountID = before.accounts[1].id; transfer.toAmount = 100
        try store.transaction { try Ledger.saveOperation(transfer, in: &$0) }; let committed = store.db!, committedBytes = try Data(contentsOf: store.url)
        store.beforeWrite = { throw BudgetError.storage("Injected") }; transfer.amount = 200; transfer.toAmount = 200
        XCTAssertThrowsError(try store.transaction { try Ledger.saveOperation(transfer, in: &$0) }); XCTAssertEqual(store.db, committed); XCTAssertEqual(try Data(contentsOf: store.url), committedBytes)
        XCTAssertThrowsError(try store.transaction { try Ledger.deleteOperation(transfer.id, in: &$0) }); XCTAssertEqual(store.db, committed); XCTAssertEqual(try Data(contentsOf: store.url), committedBytes)
        store.beforeWrite = nil; store.close(); try store.unlock(key: key); XCTAssertEqual(store.db, committed)
    }
    func testAC25AccessEnvelopeFailure() throws {
        let (root, store, _, _) = try fixture(); defer { store.close(); try? FileManager.default.removeItem(at: root) }
        let before = store.bootstrap!; var next = before; next.password = try store.withKey { try VaultCrypto.wrapPassword($0, password: "Совсем новый пароль") }
        store.beforeWrite = { throw BudgetError.storage("Injected") }; XCTAssertThrowsError(try store.changeBootstrap(next)); XCTAssertEqual(store.bootstrap, before)
        store.beforeWrite = nil; store.close(); try store.unlock(password: password)
    }
    func testAC27PortableBackupAC28DamageAndAC30Lock() throws {
        let (root, store, _, recovery) = try fixture(); defer { store.close(); try? FileManager.default.removeItem(at: root) }
        try store.transaction { db in
            let project = Project(name: "Тест переноса"); try Ledger.saveProject(project, in: &db)
            var expense = Operation(kind: .expense, accountID: db.accounts[0].id, amount: 200); expense.projectID = project.id
            expense.fx = [FXRate(base: "USD", quote: "RUB", rate: "90", date: .today)]; try Ledger.saveOperation(expense, in: &db)
            var budget = Budget(kind: .monthly, name: "План переноса", currency: "RUB", start: .today.firstOfMonth)
            budget.lines = [BudgetLine(categoryID: db.categories[0].id, limit: 10_000)]; try Ledger.saveBudget(budget, in: &db)
            var report = Report(name: "Отчёт переноса"); report.filters.accounts = [db.accounts[0].id]; db.reports = [report]
            db.dashboard[0].visible = false; db.dashboard[1].wide = false; db.dashboard.swapAt(0, 1)
            db.rates = expense.fx; db.imports = [ImportBatch(fingerprint: "test-only", added: [expense.id], skipped: 1, excluded: 2)]
        }
        let copy = root.appendingPathComponent("portable.mubak"); try store.backup(to: copy); let file = try VaultFile.read(Data(contentsOf: copy)); XCTAssertNil(file.bootstrap.password); XCTAssertFalse(file.bootstrap.touchID)
        let other = VaultStore(url: root.appendingPathComponent("other.beesave")); defer { other.close() }; let (db, imported, key) = try other.previewRestore(from: copy, recovery: recovery)
        try other.restore(database: db, dataKey: key, bootstrap: imported.bootstrap, safetyCopy: nil); XCTAssertEqual(other.db, store.db)
        let second = VaultStore(url: store.url); XCTAssertThrowsError(try second.acquire())
        var damaged = try Data(contentsOf: copy); damaged[damaged.count - 1] ^= 1; try damaged.write(to: copy); let before = store.db
        XCTAssertThrowsError(try store.previewRestore(from: copy, recovery: recovery)) { XCTAssertEqual($0 as? BudgetError, .corrupt) }; XCTAssertEqual(store.db, before)
        var newer = file; newer.bootstrap.version = 2; XCTAssertThrowsError(try VaultFile.read(newer.encoded()))
    }
}
