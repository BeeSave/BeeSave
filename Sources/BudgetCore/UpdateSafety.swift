import Foundation
import CryptoKit

/// An update snapshot retains the original password/recovery bootstrap and is
/// independent of portable backups and their rotation.
public struct UpdateSafetyRecord: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case prepared, handedOff, verified, retained }
    public let id: UUID
    public let version: String
    public let build: Int
    public let applicationPath: String
    public let vaultPath: String
    public let databaseID: UUID?
    public let snapshotSHA256: String?
    public var phase: Phase
}

public struct UpdateSafetyStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func folder(for record: UpdateSafetyRecord) -> URL { directory.appendingPathComponent(record.id.uuidString, isDirectory: true) }
    public func snapshot(for record: UpdateSafetyRecord) -> URL { folder(for: record).appendingPathComponent("vault.encrypted") }
    public func previousApplication(for record: UpdateSafetyRecord) -> URL { folder(for: record).appendingPathComponent("Previous.app", isDirectory: true) }

    public func prepare(vault: VaultStore, version: String, build: Int, application: URL) throws -> UpdateSafetyRecord {
        _ = try AppVersion(version)
        guard build > 0, application.isFileURL else { throw AppUpdateError.invalidMetadata }
        try vault.acquire()
        let id = UUID()
        // Use the record ID as the sole owned path component; never trust a path
        // from decoded JSON for deletion.
        let owned = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let bytes: Data?, file: VaultFile?
            if vault.exists {
                bytes = try Data(contentsOf: vault.url)
                file = try VaultFile.read(bytes!)
                if let database = vault.db {
                    let decoded = try vault.withKey { try file!.decrypt(key: $0) }
                    guard decoded == database, file!.bootstrap == vault.bootstrap else { throw BudgetError.corrupt }
                }
                let destination = owned.appendingPathComponent("vault.encrypted")
                try CiphertextFile.write(bytes!, to: destination)
                guard try Data(contentsOf: destination) == bytes else { throw BudgetError.corrupt }
            } else { bytes = nil; file = nil }
            let record = UpdateSafetyRecord(id: id, version: version, build: build, applicationPath: application.standardizedFileURL.path,
                                            vaultPath: vault.url.standardizedFileURL.path, databaseID: file?.bootstrap.databaseID,
                                            snapshotSHA256: bytes.map(Self.hash), phase: .prepared)
            try write(record)
            return record
        } catch {
            try? FileManager.default.removeItem(at: owned)
            throw error
        }
    }

    public func write(_ record: UpdateSafetyRecord) throws {
        try CiphertextFile.write(JSONEncoder().encode(record), to: folder(for: record).appendingPathComponent("operation.json"))
    }
    public func pending() throws -> [UpdateSafetyRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).compactMap { path in
            guard let id = UUID(uuidString: path.lastPathComponent) else { return nil }
            let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw BudgetError.corrupt }
            let record = try JSONDecoder().decode(UpdateSafetyRecord.self, from: Data(contentsOf: path.appendingPathComponent("operation.json")))
            guard record.id == id, record.build > 0 else { throw BudgetError.corrupt }
            _ = try AppVersion(record.version)
            return record
        }
    }
    /// Confirm only after the replacement launched and the original budget was
    /// opened and compared. A newer user write must never be replaced by a snapshot.
    public func verify(_ record: UpdateSafetyRecord, vault: VaultStore, version: String, build: Int, application: URL) throws {
        guard record.phase == .handedOff, record.version == version, record.build == build,
              record.applicationPath == application.standardizedFileURL.path,
              record.vaultPath == vault.url.standardizedFileURL.path else { throw BudgetError.corrupt }
        if let expectedID = record.databaseID {
            guard let database = vault.db, database.id == expectedID else { throw BudgetError.locked }
            let bytes = try Data(contentsOf: snapshot(for: record))
            guard Self.hash(bytes) == record.snapshotSHA256 else { throw BudgetError.corrupt }
            let file = try VaultFile.read(bytes)
            let original = try vault.withKey { try file.decrypt(key: $0) }
            // Opening the replacement may have migrated the original schema.
            // Compare the complete result of that same migration, including
            // revision and all user data; unrelated writes still fail closed.
            let expected = try FinancialLedger.migrate(original)
            guard database == expected else { throw BudgetError.conflict("Бюджет изменился после подготовки обновления. Защитная копия сохранена.") }
        } else {
            guard !vault.exists, record.snapshotSHA256 == nil else { throw BudgetError.corrupt }
        }
    }
    public func removeVerified(_ record: UpdateSafetyRecord, vault: VaultStore, version: String, build: Int, application: URL) throws {
        try verify(record, vault: vault, version: version, build: build, application: application)
        try FileManager.default.removeItem(at: folder(for: record))
    }
    public func cancelPrepared(_ record: UpdateSafetyRecord) throws {
        guard record.phase == .prepared else { throw BudgetError.corrupt }
        let saved = try JSONDecoder().decode(UpdateSafetyRecord.self, from: Data(contentsOf: folder(for: record).appendingPathComponent("operation.json")))
        guard saved == record else { throw BudgetError.corrupt }
        try FileManager.default.removeItem(at: folder(for: record))
    }
    public static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
