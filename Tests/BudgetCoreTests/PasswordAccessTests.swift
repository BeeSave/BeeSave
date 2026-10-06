import XCTest
@testable import BudgetCore

final class PasswordAccessTests: XCTestCase {
    private let oldPassword = "Previous password 123"
    private let newPassword = "Replacement password 456"

    private func fixture(legacy: Bool = false, biometricFlag: Bool = false) throws -> (URL, VaultStore, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VaultStore(url: root.appendingPathComponent("vault.beesave"))
        var db = Database()
        try Ledger.saveAccount(Account(name: "Existing savings", currency: "RUB"), opening: 120_000, in: &db)
        try Ledger.saveOperation(Operation(kind: .expense, accountID: db.accounts[0].id, amount: 2_400), in: &db)
        db.settings.lockMinutes = 15
        db.settings.backupPath = "/saved/backup/location"
        db.dashboard[0].visible = false
        let key = try VaultCrypto.random(), recoveryKey = try VaultCrypto.random()
        let envelope = legacy ? nil : try VaultCrypto.wrapPassword(key, password: oldPassword)
        let bootstrap = Bootstrap(databaseID: db.id, password: envelope,
                                  recovery: try VaultCrypto.seal(key, key: recoveryKey, context: VaultCrypto.recoveryContext),
                                  touchID: biometricFlag)
        try store.initialize(db: db, dataKey: key, bootstrap: bootstrap)
        return (root, store, VaultCrypto.recoveryString(recoveryKey))
    }

    func testPasswordChangePreservesBudgetIdentityAndRecovery() throws {
        let (root, store, recovery) = try fixture(biometricFlag: true)
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        let database = store.db!, original = store.bootstrap!
        try store.changePassword(current: oldPassword, newPassword: newPassword)
        XCTAssertEqual(store.db, database)
        XCTAssertEqual(store.bootstrap?.databaseID, original.databaseID)
        XCTAssertEqual(store.bootstrap?.localKeyID, original.localKeyID)
        XCTAssertEqual(store.bootstrap?.recovery, original.recovery)
        XCTAssertFalse(store.bootstrap!.touchID)
        store.close()
        XCTAssertThrowsError(try store.unlock(password: oldPassword))
        XCTAssertNil(store.db)
        try store.unlock(password: newPassword)
        XCTAssertEqual(store.db, database)
        store.close()
        try store.unlock(recovery: recovery)
        XCTAssertEqual(store.db, database)
    }

    func testLegacyBudgetsRequireExplicitRecoveryAndReceivePassword() throws {
        for biometricFlag in [false, true] {
            let (root, store, recovery) = try fixture(legacy: true, biometricFlag: biometricFlag)
            defer { store.close(); try? FileManager.default.removeItem(at: root) }
            let database = store.db!, original = store.bootstrap!
            store.close()
            let bytes = try Data(contentsOf: store.url)
            XCTAssertThrowsError(try store.unlock(password: oldPassword))
            XCTAssertNil(store.db)
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
            try store.resetPassword(recovery: recovery, newPassword: newPassword)
            XCTAssertEqual(store.db, database)
            XCTAssertEqual(store.bootstrap?.localKeyID, original.localKeyID)
            XCTAssertEqual(store.bootstrap?.recovery, original.recovery)
            XCTAssertFalse(store.bootstrap!.touchID)
            store.close()
            try store.unlock(password: newPassword)
            XCTAssertEqual(store.db, database)
        }
    }

    func testInvalidRecoveryAndWeakPasswordLeaveLockedFileUntouched() throws {
        let (root, store, recovery) = try fixture()
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        store.close()
        let bytes = try Data(contentsOf: store.url)
        let unrelated = VaultCrypto.recoveryString(try VaultCrypto.random())
        XCTAssertThrowsError(try store.resetPassword(recovery: unrelated, newPassword: newPassword))
        XCTAssertThrowsError(try store.resetPassword(recovery: recovery, newPassword: ""))
        XCTAssertThrowsError(try store.resetPassword(recovery: recovery, newPassword: "short"))
        XCTAssertNil(store.db)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        try store.unlock(password: oldPassword)
    }

    func testResetWriteFailureNeverOpensOrReplacesBudget() throws {
        let (root, store, recovery) = try fixture()
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        let original = store.bootstrap!
        store.close()
        let bytes = try Data(contentsOf: store.url)
        store.beforeWrite = { throw BudgetError.storage("Injected disk failure") }
        XCTAssertThrowsError(try store.resetPassword(recovery: recovery, newPassword: newPassword))
        XCTAssertNil(store.db)
        XCTAssertEqual(store.bootstrap, original)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        store.beforeWrite = nil
        try store.unlock(password: oldPassword)
        try store.resetPassword(recovery: recovery, newPassword: newPassword)
        XCTAssertEqual(store.bootstrap?.recovery, original.recovery)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".encrypted") })
    }

    func testFailedPasswordChangePreservesOpenSessionAndOldPassword() throws {
        let (root, store, _) = try fixture()
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        let database = store.db!, original = store.bootstrap!, bytes = try Data(contentsOf: store.url)
        XCTAssertThrowsError(try store.changePassword(current: "wrong", newPassword: newPassword))
        XCTAssertThrowsError(try store.changePassword(current: oldPassword, newPassword: ""))
        store.beforeWrite = { throw BudgetError.storage("Injected disk failure") }
        XCTAssertThrowsError(try store.changePassword(current: oldPassword, newPassword: newPassword))
        XCTAssertEqual(store.db, database)
        XCTAssertEqual(store.bootstrap, original)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        store.beforeWrite = nil
        store.close()
        try store.unlock(password: oldPassword)
        XCTAssertEqual(store.db, database)
    }

    func testPasswordChangeCanBeAuthorizedWithExistingRecovery() throws {
        let (root, store, recovery) = try fixture()
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        let database = store.db!
        try store.changePassword(current: recovery, useRecovery: true, newPassword: newPassword)
        store.close()
        try store.unlock(password: newPassword)
        XCTAssertEqual(store.db, database)
    }
}
