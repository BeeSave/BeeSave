import XCTest
@testable import BudgetCore

final class BackupTests: XCTestCase {
    func testDailyRetentionAndFailedRestoreKeepCurrentFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VaultStore(url: root.appendingPathComponent("vault.beesave"))
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        var db = Database(); try Ledger.saveAccount(Account(name: "Банк", currency: "RUB"), opening: 100_000, in: &db)
        let key = try VaultCrypto.random(), recovery = try VaultCrypto.random()
        let bootstrap = Bootstrap(databaseID: db.id, password: nil, recovery: try VaultCrypto.seal(key, key: recovery, context: VaultCrypto.recoveryContext))
        try store.initialize(db: db, dataKey: key, bootstrap: bootstrap)
        let folder = root.appendingPathComponent("copies")
        let manual = folder.appendingPathComponent("manual.mubak")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try store.backup(to: manual)
        for i in 0..<32 { _ = try Backups.write(store: store, folder: folder, kind: "daily", now: Day.today.adding(-i).date) }
        for _ in 0..<12 { _ = try Backups.write(store: store, folder: folder, kind: "service") }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.filter { $0.hasPrefix("daily-") }.count, 30)
        XCTAssertEqual(files.filter { $0.hasPrefix("service-") }.count, 10)
        XCTAssertTrue(files.contains("manual.mubak"))
        try Backups.daily(store: store, folder: folder); let revision = store.db?.revision
        XCTAssertEqual(store.db?.settings.lastDaily, .today)
        try Backups.daily(store: store, folder: folder); XCTAssertEqual(store.db?.revision, revision)
        let before = try Data(contentsOf: store.url), current = store.db
        let badFolder = root.appendingPathComponent("unusable"); try Data("occupied".utf8).write(to: badFolder)
        XCTAssertNoThrow(try Backups.daily(store: store, folder: badFolder.appendingPathComponent("child"))) // Already copied today: no write needed.
        store.beforeWrite = { throw BudgetError.storage("Injected full disk") }
        var replacement = db; replacement.accounts[0].name = "Замена"
        XCTAssertThrowsError(try store.restore(database: replacement, dataKey: key, bootstrap: bootstrap, safetyCopy: folder.appendingPathComponent("before-restore.mubak")))
        XCTAssertEqual(store.db, current); XCTAssertEqual(try Data(contentsOf: store.url), before)
        store.beforeWrite = nil
        let portable = try VaultFile.read(Data(contentsOf: manual)); XCTAssertEqual(try portable.decrypt(key: key), db)
    }

    func testBackupFailureDoesNotUndoOrdinarySavedOperation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VaultStore(url: root.appendingPathComponent("vault.beesave")); defer { store.close(); try? FileManager.default.removeItem(at: root) }
        var db = Database(); let a = Account(name: "Банк", currency: "RUB"); try Ledger.saveAccount(a, in: &db)
        let key = try VaultCrypto.random(), recovery = try VaultCrypto.random()
        try store.initialize(db: db, dataKey: key, bootstrap: Bootstrap(databaseID: db.id, password: nil, recovery: try VaultCrypto.seal(key, key: recovery, context: VaultCrypto.recoveryContext)))
        try store.transaction { try Ledger.saveOperation(Operation(kind: .income, accountID: a.id, amount: 500), in: &$0) }
        let badFolder = root.appendingPathComponent("unusable"); try Data("occupied".utf8).write(to: badFolder)
        XCTAssertThrowsError(try Backups.daily(store: store, folder: badFolder)); XCTAssertEqual(try store.db?.balance(a.id), 500)
        XCTAssertThrowsError(try Backups.beforeMassChange(store: store, folder: badFolder)); XCTAssertEqual(store.db?.operations.count, 1)
    }
}
