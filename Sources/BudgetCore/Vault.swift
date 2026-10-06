import Foundation
import Darwin

public struct Bootstrap: Codable, Equatable, Sendable {
    public var version = 1; public var databaseID: UUID; public var password: KeyEnvelope?; public var recovery: Data; public var touchID = false; public var localKeyID = UUID()
    public init(databaseID: UUID, password: KeyEnvelope?, recovery: Data, touchID: Bool = false) { self.databaseID = databaseID; self.password = password; self.recovery = recovery; self.touchID = touchID }
}
public struct VaultFile: Sendable {
    public var bootstrap: Bootstrap; public var payload: Data
    private static let magic = Data("MUBUDG01".utf8)
    // Preserve the version-one context so existing ciphertext and backups open.
    private static func dataContext(_ id: UUID) -> String { "MuBudget data v1 " + id.uuidString }
    public init(bootstrap: Bootstrap, payload: Data) { self.bootstrap = bootstrap; self.payload = payload }
    public static func read(_ data: Data) throws -> VaultFile {
        guard data.count >= 12, data.prefix(8) == magic else { throw BudgetError.corrupt }
        let n = data[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard n > 0, n <= 1_048_576, data.count >= 12 + Int(n) + 28 else { throw BudgetError.corrupt }
        let b: Bootstrap
        do { b = try JSONDecoder().decode(Bootstrap.self, from: data[12..<12 + Int(n)]) } catch { throw BudgetError.corrupt }
        guard b.version <= 1 else { throw BudgetError.newerVersion }; guard b.version == 1 else { throw BudgetError.corrupt }
        return VaultFile(bootstrap: b, payload: Data(data.dropFirst(12 + Int(n))))
    }
    public func encoded() throws -> Data {
        let header = try JSONEncoder().encode(bootstrap); guard header.count < 1_048_576 else { throw BudgetError.corrupt }
        let n = UInt32(header.count); var out = Self.magic; out.append(contentsOf: [UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]); out.append(header); out.append(payload); return out
    }
    public static func make(db: Database, key: Data, bootstrap: Bootstrap) throws -> VaultFile {
        let plain = try JSONEncoder().encode(db)
        return VaultFile(bootstrap: bootstrap, payload: try VaultCrypto.seal(plain, key: key, context: dataContext(bootstrap.databaseID)))
    }
    public func decrypt(key: Data) throws -> Database {
        let data: Data
        do { data = try VaultCrypto.open(payload, key: key, context: Self.dataContext(bootstrap.databaseID)) }
        catch { throw BudgetError.corrupt }
        let db: Database; do { db = try JSONDecoder().decode(Database.self, from: data) } catch { throw BudgetError.corrupt }
        guard db.id == bootstrap.databaseID else { throw BudgetError.corrupt }; try Ledger.validate(db); return db
    }
    public func recoveryUnlock(_ string: String) throws -> Data { try VaultCrypto.open(bootstrap.recovery, key: VaultCrypto.recoveryKey(string), context: VaultCrypto.recoveryContext) }
    public func portable() -> VaultFile { var copy = self; copy.bootstrap.password = nil; copy.bootstrap.touchID = false; copy.bootstrap.localKeyID = UUID(); return copy }
}

public final class VaultStore {
    public let url: URL; public private(set) var db: Database?; public private(set) var bootstrap: Bootstrap?; private var key: Data?; private var lockFD: Int32 = -1
    /// Test hook runs after ciphertext is prepared and before the atomic write. No plaintext ever reaches it.
    public var beforeWrite: (() throws -> Void)?
    public init(url: URL) { self.url = url }
    deinit { close() }
    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    public func acquire() throws {
        guard lockFD == -1 else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw BudgetError.storage("Не удалось открыть локальное хранилище. Проверьте путь и права.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw BudgetError.busy }; lockFD = fd
    }
    public func inspect() throws -> Bootstrap { let b = try VaultFile.read(Data(contentsOf: url)).bootstrap; bootstrap = b; return b }
    public func initialize(db: Database, dataKey: Data, bootstrap b: Bootstrap) throws {
        try acquire(); guard !exists else { throw BudgetError.conflict("База уже существует. Используйте вход или восстановление.") }; try Ledger.validate(db); try persist(db, key: dataKey, bootstrap: b); self.db = db; key = dataKey; bootstrap = b
    }
    public func unlock(key dataKey: Data) throws {
        try acquire(); let file = try VaultFile.read(Data(contentsOf: url)); let original = try file.decrypt(key: dataKey)
        let database = try prepareMigration(original, file: file, key: dataKey)
        if original.version != database.version { try persist(database, key: dataKey, bootstrap: file.bootstrap) }
        db = database; key = dataKey; bootstrap = file.bootstrap
    }
    private func prepareMigration(_ original: Database, file: VaultFile, key: Data) throws -> Database {
        guard original.version == 1 else { return original }
        let folder = url.deletingLastPathComponent().appendingPathComponent("Backups.noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent("schema-1-" + UUID().uuidString + ".mubak")
        let backup = try file.portable().encoded()
        try CiphertextFile.write(backup, to: destination)
        let checked = try VaultFile.read(Data(contentsOf: destination)).decrypt(key: key)
        guard checked == original else { throw BudgetError.storage("Исходная копия перед обновлением схемы не прошла проверку; бюджет сохранён без изменений.") }
        return try FinancialLedger.migrate(original)
    }
    public func unlock(password: String) throws { let b = try inspect(); guard let env = b.password else { throw BudgetError.invalid("Задайте пароль с помощью ключа восстановления.") }; try unlock(key: VaultCrypto.unwrapPassword(env, password: password)) }
    public func unlock(recovery: String) throws { let file = try VaultFile.read(Data(contentsOf: url)); try unlock(key: file.recoveryUnlock(recovery)) }
    /// Recovery is an explicit password reset. Publish an unlocked session only
    /// after the new envelope has been atomically persisted and verified.
    public func resetPassword(recovery: String, newPassword: String) throws {
        try acquire()
        let file = try VaultFile.read(Data(contentsOf: url))
        let recoveredKey = try file.recoveryUnlock(recovery)
        let original = try file.decrypt(key: recoveredKey)
        let database = try prepareMigration(original, file: file, key: recoveredKey)
        var next = file.bootstrap
        next.password = try VaultCrypto.wrapPassword(recoveredKey, password: newPassword)
        next.touchID = false
        try persist(database, key: recoveredKey, bootstrap: next)
        db = database; key = recoveredKey; bootstrap = next
    }
    public func changePassword(current: String, useRecovery: Bool = false, newPassword: String) throws {
        if useRecovery { try verifyRecovery(current) } else { try verifyPassword(current) }
        guard var next = bootstrap else { throw BudgetError.locked }
        next.password = try withKey { try VaultCrypto.wrapPassword($0, password: newPassword) }
        next.touchID = false
        try changeBootstrap(next)
    }
    public func transaction(_ change: (inout Database) throws -> Void) throws {
        guard var candidate = db, let key, let b = bootstrap else { throw BudgetError.locked }
        let (revision, overflow) = (candidate.revision ?? 0).addingReportingOverflow(1)
        guard !overflow else { throw BudgetError.overflow }
        try change(&candidate); candidate.revision = revision; try Ledger.validate(candidate); try persist(candidate, key: key, bootstrap: b); db = candidate
    }
    public func changeBootstrap(_ new: Bootstrap) throws {
        guard let db, let key else { throw BudgetError.locked }; try persist(db, key: key, bootstrap: new); bootstrap = new
    }
    public func verifyPassword(_ password: String) throws { guard let env = bootstrap?.password, let key else { throw BudgetError.locked }; guard try VaultCrypto.unwrapPassword(env, password: password) == key else { throw BudgetError.wrongKey } }
    public func verifyRecovery(_ recovery: String) throws { guard let b = bootstrap, let key else { throw BudgetError.locked }; guard try VaultCrypto.open(b.recovery, key: VaultCrypto.recoveryKey(recovery), context: VaultCrypto.recoveryContext) == key else { throw BudgetError.wrongKey } }
    public func withKey<T>(_ body: (Data) throws -> T) throws -> T { guard let key else { throw BudgetError.locked }; return try body(key) }
    private func persist(_ db: Database, key: Data, bootstrap: Bootstrap) throws {
        let bytes = try VaultFile.make(db: db, key: key, bootstrap: bootstrap).encoded(); try beforeWrite?()
        do { try CiphertextFile.write(bytes, to: url) }
        catch { throw BudgetError.storage("Не удалось сохранить базу. Освободите место, проверьте права и повторите.") }
    }
    public func backup(to destination: URL) throws {
        guard let db, let key, let b = bootstrap else { throw BudgetError.locked }
        let file = try VaultFile.make(db: db, key: key, bootstrap: b).portable(); let bytes = try file.encoded()
        do { try CiphertextFile.write(bytes, to: destination)
            let check = try VaultFile.read(Data(contentsOf: destination)); guard try check.decrypt(key: key) == db else { throw BudgetError.corrupt }
        } catch { throw BudgetError.storage("Копия не записана или не прошла проверку. Выберите другой путь и проверьте свободное место.") }
    }
    public func previewRestore(from source: URL, recovery: String) throws -> (Database, VaultFile, Data) {
        let file = try VaultFile.read(Data(contentsOf: source)); let newKey = try file.recoveryUnlock(recovery); let newDB = try file.decrypt(key: newKey); return (newDB, file, newKey)
    }
    public func restore(database: Database, dataKey: Data, bootstrap: Bootstrap, safetyCopy: URL?) throws {
        try acquire(); try Ledger.validate(database)
        if exists { guard let safetyCopy else { throw BudgetError.invalid("Перед заменой требуется полная копия текущих данных.") }; try backup(to: safetyCopy) }
        let migrated = try FinancialLedger.migrate(database)
        try persist(migrated, key: dataKey, bootstrap: bootstrap); db = migrated; key = dataKey; self.bootstrap = bootstrap
    }
    public func close() {
        db = nil; if var data = key { data.resetBytes(in: 0..<data.count) }; key = nil
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1 }
    }
}

/// The only disk intermediate is ciphertext. All fallible writes and permission changes
/// precede rename, so a reported failure leaves the previous database intact.
enum CiphertextFile {
    static func write(_ bytes: Data, to destination: URL) throws {
        let folder = destination.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".beesave-" + UUID().uuidString + ".encrypted")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw BudgetError.storage("Не удалось создать защищённый временный файл.") }
        defer { Darwin.close(fd); _ = Darwin.unlink(temporary.path) }
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw BudgetError.storage("Не удалось записать файл целиком.") }
                offset += written
            }
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { throw BudgetError.storage("Не удалось завершить запись защищённого файла.") }
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw BudgetError.storage("Не удалось атомарно заменить файл.") }
        let directory = Darwin.open(folder.path, O_RDONLY)
        if directory >= 0 { _ = fsync(directory); Darwin.close(directory) }
    }
}
