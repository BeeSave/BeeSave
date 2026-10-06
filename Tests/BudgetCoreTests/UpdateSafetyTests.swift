import XCTest
@testable import BudgetCore

final class UpdateSafetyTests: XCTestCase {
    private func fixture() throws -> (URL, VaultStore, UpdateSafetyStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault = VaultStore(url: root.appendingPathComponent("vault.beesave"))
        var database = Database()
        try Ledger.saveAccount(Account(name: "Original budget", currency: "RUB"), opening: 12_345, in: &database)
        database.settings.backupPath = "/external/backups"
        database.dashboard[0].visible = false
        let key = try VaultCrypto.random(), recovery = try VaultCrypto.random()
        let bootstrap = Bootstrap(databaseID: database.id, password: try VaultCrypto.wrapPassword(key, password: "Original password 123"),
                                  recovery: try VaultCrypto.seal(key, key: recovery, context: VaultCrypto.recoveryContext))
        try vault.initialize(db: database, dataKey: key, bootstrap: bootstrap)
        return (root, vault, UpdateSafetyStore(directory: root.appendingPathComponent("UpdateSafety.noindex")), root.appendingPathComponent("BeeSave.app"))
    }
    func testRawSnapshotPreservesBootstrapAndExistingBackups() throws {
        let (root, vault, safety, app) = try fixture()
        defer { vault.close(); try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: vault.url), bootstrap = vault.bootstrap
        let backup = root.appendingPathComponent("Existing.mubak")
        try vault.backup(to: backup)
        let backupBytes = try Data(contentsOf: backup)
        let record = try safety.prepare(vault: vault, version: "1.2.0", build: 6, application: app)
        XCTAssertEqual(try Data(contentsOf: safety.snapshot(for: record)), original)
        XCTAssertEqual(try VaultFile.read(Data(contentsOf: safety.snapshot(for: record))).bootstrap, bootstrap)
        XCTAssertEqual(try Data(contentsOf: vault.url), original)
        XCTAssertEqual(try Data(contentsOf: backup), backupBytes)
        XCTAssertEqual(try safety.pending(), [record])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: safety.snapshot(for: record).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: safety.folder(for: record).path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    func testLockedBudgetCanBeSnapshottedButCannotBeAcknowledged() throws {
        let (root, vault, safety, app) = try fixture()
        defer { vault.close(); try? FileManager.default.removeItem(at: root) }
        let database = vault.db
        vault.close()
        var record = try safety.prepare(vault: vault, version: "1.2.0", build: 6, application: app)
        record.phase = .handedOff; try safety.write(record)
        XCTAssertNil(vault.db)
        XCTAssertThrowsError(try safety.removeVerified(record, vault: vault, version: "1.2.0", build: 6, application: app))
        XCTAssertTrue(FileManager.default.fileExists(atPath: safety.snapshot(for: record).path))
        try vault.unlock(password: "Original password 123")
        XCTAssertEqual(vault.db, database)
        try safety.removeVerified(record, vault: vault, version: "1.2.0", build: 6, application: app)
        XCTAssertTrue(try safety.pending().isEmpty)
    }
    func testWrongVersionPathAndTamperedSnapshotNeverRemoveSafetyFiles() throws {
        let (root, vault, safety, app) = try fixture()
        defer { vault.close(); try? FileManager.default.removeItem(at: root) }
        var record = try safety.prepare(vault: vault, version: "1.2.0", build: 6, application: app)
        record.phase = .handedOff; try safety.write(record)
        let original = try Data(contentsOf: vault.url)
        XCTAssertThrowsError(try safety.removeVerified(record, vault: vault, version: "1.2.0", build: 7, application: app))
        XCTAssertThrowsError(try safety.removeVerified(record, vault: vault, version: "1.2.0", build: 6, application: root.appendingPathComponent("Other.app")))
        var snapshot = try Data(contentsOf: safety.snapshot(for: record)); snapshot[snapshot.count - 1] ^= 1
        try snapshot.write(to: safety.snapshot(for: record))
        XCTAssertThrowsError(try safety.removeVerified(record, vault: vault, version: "1.2.0", build: 6, application: app))
        XCTAssertEqual(try Data(contentsOf: vault.url), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: safety.folder(for: record).path))
    }
    func testNewerUserWriteIsKeptAndSafetyCopyRemains() throws {
        let (root, vault, safety, app) = try fixture()
        defer { vault.close(); try? FileManager.default.removeItem(at: root) }
        var record = try safety.prepare(vault: vault, version: "1.2.0", build: 6, application: app)
        record.phase = .handedOff; try safety.write(record)
        try vault.transaction { $0.accounts[0].name = "New confirmed user input" }
        let current = try Data(contentsOf: vault.url)
        XCTAssertThrowsError(try safety.removeVerified(record, vault: vault, version: "1.2.0", build: 6, application: app))
        XCTAssertEqual(try Data(contentsOf: vault.url), current)
        XCTAssertEqual(vault.db?.accounts[0].name, "New confirmed user input")
        XCTAssertTrue(FileManager.default.fileExists(atPath: safety.snapshot(for: record).path))
    }
    func testSnapshotFailurePreservesOriginalAndPreparedPhaseCannotBeAcknowledged() throws {
        let (root, vault, safety, app) = try fixture()
        defer { vault.close(); try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: vault.url)
        let occupied = root.appendingPathComponent("Occupied"); try Data([1]).write(to: occupied)
        let blocked = UpdateSafetyStore(directory: occupied.appendingPathComponent("child"))
        XCTAssertThrowsError(try blocked.prepare(vault: vault, version: "1.2.0", build: 6, application: app))
        XCTAssertEqual(try Data(contentsOf: vault.url), original)
        let record = try safety.prepare(vault: vault, version: "1.2.0", build: 6, application: app)
        XCTAssertThrowsError(try safety.removeVerified(record, vault: vault, version: "1.2.0", build: 6, application: app))
        XCTAssertEqual(try safety.pending(), [record])
    }
    func testProfileWithoutBudgetIsNotInitializedByUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault = VaultStore(url: root.appendingPathComponent("vault.beesave"))
        defer { vault.close(); try? FileManager.default.removeItem(at: root) }
        let safety = UpdateSafetyStore(directory: root.appendingPathComponent("UpdateSafety.noindex")), app = root.appendingPathComponent("BeeSave.app")
        var record = try safety.prepare(vault: vault, version: "1.2.0", build: 6, application: app)
        XCTAssertNil(record.databaseID)
        XCTAssertFalse(vault.exists)
        record.phase = .handedOff; try safety.write(record)
        try safety.removeVerified(record, vault: vault, version: "1.2.0", build: 6, application: app)
        XCTAssertFalse(vault.exists)
    }
    func testCancelledPreparedOperationRemovesOnlyItsOwnFiles() throws {
        let (root, vault, safety, app) = try fixture()
        defer { vault.close(); try? FileManager.default.removeItem(at: root) }
        let first = try safety.prepare(vault: vault, version: "1.2.0", build: 6, application: app)
        var second = try safety.prepare(vault: vault, version: "1.3.0", build: 7, application: app)
        let bytes = try Data(contentsOf: vault.url)
        try safety.cancelPrepared(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: safety.folder(for: first).path))
        XCTAssertEqual(try safety.pending(), [second])
        second.phase = .handedOff; try safety.write(second)
        XCTAssertThrowsError(try safety.cancelPrepared(second))
        XCTAssertEqual(try Data(contentsOf: vault.url), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: safety.snapshot(for: second).path))
    }
    func testPendingSymbolicLinkCannotRedirectOperationReads() throws {
        let (root, vault, safety, app) = try fixture()
        defer { vault.close(); try? FileManager.default.removeItem(at: root) }
        let record = try safety.prepare(vault: vault, version: "1.2.0", build: 6, application: app)
        let link = safety.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: safety.folder(for: record))
        XCTAssertThrowsError(try safety.pending())
        XCTAssertTrue(FileManager.default.fileExists(atPath: safety.snapshot(for: record).path))
    }
}
