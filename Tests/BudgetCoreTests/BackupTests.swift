import XCTest
@testable import BudgetCore

final class BackupTests: XCTestCase {
    func testBackgroundSnapshotAndStampPreserveInterveningWritesAndSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VaultStore(url: root.appendingPathComponent("vault.beesave"))
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        let db = Database(), key = try VaultCrypto.random()
        let bootstrap = Bootstrap(databaseID: db.id, password: nil, recovery: Data())
        try store.initialize(db: db, dataKey: key, bootstrap: bootstrap)
        let snapshot = try store.snapshot()
        let prepared = try snapshot.recordingDailyBackup(day: .today, completedAt: Date())
        try store.transaction { $0.settings.baseCurrency = "USD" }
        let before = try Data(contentsOf: store.url)
        XCTAssertFalse(try store.applyBackupStamp(prepared))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        let copy = root.appendingPathComponent("snapshot.mubak")
        try snapshot.backup(to: copy)
        XCTAssertEqual(try VaultFile.read(Data(contentsOf: copy)).decrypt(key: key), db)
        let retry = try store.snapshot().recordingDailyBackup(day: .today, completedAt: Date())
        XCTAssertTrue(try store.applyBackupStamp(retry))
        XCTAssertEqual(store.db?.settings.baseCurrency, "USD")
        XCTAssertEqual(store.db?.settings.lastDaily, .today)
        XCTAssertEqual(try VaultFile.read(Data(contentsOf: store.url)).decrypt(key: key), store.db)
        let oldSession = try store.snapshot().recordingDailyBackup(day: .today, completedAt: Date())
        store.close(); try store.unlock(key: key)
        let reopened = try Data(contentsOf: store.url)
        XCTAssertFalse(try store.applyBackupStamp(oldSession))
        XCTAssertEqual(try Data(contentsOf: store.url), reopened)
        let oldBootstrap = try store.snapshot().recordingDailyBackup(day: .today, completedAt: Date())
        var next = bootstrap; next.localKeyID = UUID()
        try store.changeBootstrap(next)
        XCTAssertFalse(try store.applyBackupStamp(oldBootstrap))
        XCTAssertEqual(store.bootstrap, next)
    }

    func testFailedBackgroundStampPreservesDatabaseAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VaultStore(url: root.appendingPathComponent("vault.beesave"))
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        let db = Database(), key = try VaultCrypto.random()
        try store.initialize(db: db, dataKey: key, bootstrap: Bootstrap(databaseID: db.id, password: nil, recovery: Data()))
        let prepared = try store.snapshot().recordingDailyBackup(day: .today, completedAt: Date())
        let before = try Data(contentsOf: store.url)
        store.beforeWrite = { throw BudgetError.storage("Injected write failure") }
        XCTAssertThrowsError(try store.applyBackupStamp(prepared))
        XCTAssertEqual(store.db, db)
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        store.beforeWrite = nil
        XCTAssertTrue(try store.applyBackupStamp(prepared))
        XCTAssertEqual(store.db?.settings.lastDaily, .today)
    }

    func testFailedExternalReplacementPreservesVerifiedCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VaultStore(url: root.appendingPathComponent("vault.beesave"))
        let folder = root.appendingPathComponent("external")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path); store.close(); try? FileManager.default.removeItem(at: root) }
        let db = Database(), key = try VaultCrypto.random(), recovery = try VaultCrypto.random()
        try store.initialize(db: db, dataKey: key, bootstrap: Bootstrap(databaseID: db.id, password: nil, recovery: try VaultCrypto.seal(key, key: recovery, context: VaultCrypto.recoveryContext)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("copy.mubak")
        try store.backup(to: copy)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let original = try Data(contentsOf: copy)
        try store.transaction { try Ledger.saveAccount(Account(name: "Изменённая тестовая база", currency: "RUB"), in: &$0) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try store.backup(to: copy))
        XCTAssertEqual(try Data(contentsOf: copy), original)
        XCTAssertEqual(try VaultFile.read(original).decrypt(key: key), db)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try store.backup(to: copy)
        XCTAssertEqual(try VaultFile.read(Data(contentsOf: copy)).decrypt(key: key), store.db)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

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
