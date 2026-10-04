import XCTest
@testable import BudgetCore

final class BrandCompatibilityTests: XCTestCase {
    func testFreshInstallationUsesBeeSaveLocation() {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let location = StorageLocation(applicationSupport: support)
        XCTAssertEqual(location.directory.lastPathComponent, "BeeSave.noindex")
        XCTAssertEqual(location.vault.lastPathComponent, "vault.beesave")
    }

    func testExistingVaultIsOpenedInPlaceAndKeepsItsLock() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let legacy = support.appendingPathComponent("MuBudget.noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let url = legacy.appendingPathComponent("vault.mubudget")
        try Data().write(to: url)
        let location = StorageLocation(applicationSupport: support)
        XCTAssertEqual(location.vault, url)
        let original = VaultStore(url: url)
        let renamed = VaultStore(url: location.vault)
        defer { original.close(); renamed.close() }
        try original.acquire()
        XCTAssertThrowsError(try renamed.acquire()) { XCTAssertEqual($0 as? BudgetError, .busy) }
    }

    func testCurrentVaultTakesPriorityWithoutChangingEitherFile() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        for (folder, file) in [("BeeSave.noindex", "vault.beesave"), ("MuBudget.noindex", "vault.mubudget")] {
            let directory = support.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(folder.utf8).write(to: directory.appendingPathComponent(file))
        }
        let location = StorageLocation(applicationSupport: support)
        XCTAssertEqual(location.vault.lastPathComponent, "vault.beesave")
        XCTAssertEqual(try Data(contentsOf: location.vault), Data("BeeSave.noindex".utf8))
        XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent("MuBudget.noindex/vault.mubudget")), Data("MuBudget.noindex".utf8))
    }

    func testPreRebrandVersionOneVaultAndBackupRemainReadable() throws {
        // Construct the old on-disk format independently of BeeSave's writer.
        var database = Database()
        try Ledger.saveAccount(Account(name: "Legacy fixture", currency: "RUB"), opening: 12_345, in: &database)
        let key = Data(repeating: 0x31, count: 32)
        let recoveryKey = Data(repeating: 0x52, count: 32)
        let password = "Legacy fixture password"
        var envelope = KeyEnvelope(salt: Data(repeating: 0x73, count: 16), sealed: Data())
        let derived = try VaultCrypto.derive(password: password, envelope: envelope)
        envelope.sealed = try VaultCrypto.seal(key, key: derived, context: "MuBudget password v1")
        let recovery = try VaultCrypto.seal(key, key: recoveryKey, context: "MuBudget recovery v1")
        let bootstrap = Bootstrap(databaseID: database.id, password: envelope, recovery: recovery)
        let payload = try VaultCrypto.seal(JSONEncoder().encode(database), key: key, context: "MuBudget data v1 " + database.id.uuidString)
        let header = try JSONEncoder().encode(bootstrap)
        let size = UInt32(header.count)
        var bytes = Data("MUBUDG01".utf8)
        bytes.append(contentsOf: [UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        bytes.append(header); bytes.append(payload)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("vault.mubudget")
        try bytes.write(to: url)
        let store = VaultStore(url: url)
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        try store.unlock(password: password)
        XCTAssertEqual(store.db, database)
        store.close()
        let recoveryString = VaultCrypto.recoveryString(recoveryKey)
        try store.unlock(recovery: recoveryString)
        XCTAssertEqual(store.db, database)
        try store.transaction { $0.settings.lockMinutes = 15 }
        let updated = store.db
        let backup = root.appendingPathComponent("BeeSave.mubak")
        try store.backup(to: backup)
        let restored = try store.previewRestore(from: backup, recovery: recoveryString)
        XCTAssertEqual(restored.0, updated)
        store.close()
        try store.unlock(password: password)
        XCTAssertEqual(store.db, updated)
    }
}
