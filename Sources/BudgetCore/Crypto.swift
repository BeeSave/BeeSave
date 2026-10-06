import Foundation
import CryptoKit
import Security
import CArgon2

public struct KeyEnvelope: Codable, Equatable, Sendable {
    public var version = 1; public var salt: Data; public var memory: UInt32 = 19_456; public var passes: UInt32 = 2; public var lanes: UInt32 = 1; public var sealed: Data
    public init(salt: Data, sealed: Data) { self.salt = salt; self.sealed = sealed }
}
public enum VaultCrypto {
    // Version-one authenticated data is part of the file format, not app branding.
    // Changing these bytes would invalidate existing password and recovery keys.
    private static let passwordContext = "MuBudget password v1"
    public static let recoveryContext = "MuBudget recovery v1"
    public static func random(_ count: Int = 32) throws -> Data {
        var bytes = Data(count: count); let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BudgetError.storage("Не удалось создать защищённый ключ.") }; return bytes
    }
    public static func derive(password: String, envelope: KeyEnvelope) throws -> Data {
        guard envelope.version == 1, envelope.salt.count >= 16, envelope.salt.count <= 64, envelope.memory >= 19_456, envelope.memory <= 262_144, envelope.passes >= 2, envelope.passes <= 10, envelope.lanes == 1 else { throw BudgetError.corrupt }
        var pass = Data(password.utf8); var output = Data(count: 32)
        defer { pass.resetBytes(in: 0..<pass.count) }
        let status = pass.withUnsafeBytes { p in envelope.salt.withUnsafeBytes { s in output.withUnsafeMutableBytes { o in argon2id_hash_raw(envelope.passes, envelope.memory, envelope.lanes, p.baseAddress, p.count, s.baseAddress, s.count, o.baseAddress, o.count) } } }
        guard status == ARGON2_OK.rawValue else { throw BudgetError.storage("Не удалось обработать пароль (Argon2).") }; return output
    }
    public static func seal(_ data: Data, key: Data, context: String) throws -> Data {
        guard key.count == 32 else { throw BudgetError.corrupt }
        return try AES.GCM.seal(data, using: SymmetricKey(data: key), authenticating: Data(context.utf8)).combined!
    }
    public static func open(_ data: Data, key: Data, context: String) throws -> Data {
        guard key.count == 32 else { throw BudgetError.wrongKey }
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key), authenticating: Data(context.utf8)) }
        catch { throw BudgetError.wrongKey }
    }
    public static func wrapPassword(_ key: Data, password: String) throws -> KeyEnvelope {
        guard password.count >= 12 else { throw BudgetError.invalid("Пароль должен содержать не менее 12 символов.") }
        var env = KeyEnvelope(salt: try random(16), sealed: Data()); var derived = try derive(password: password, envelope: env); defer { derived.resetBytes(in: 0..<derived.count) }
        env.sealed = try seal(key, key: derived, context: passwordContext)
        guard try unwrapPassword(env, password: password) == key else { throw BudgetError.corrupt }; return env
    }
    public static func unwrapPassword(_ env: KeyEnvelope, password: String) throws -> Data {
        var derived = try derive(password: password, envelope: env); defer { derived.resetBytes(in: 0..<derived.count) }
        return try open(env.sealed, key: derived, context: passwordContext)
    }
    public static func recoveryString(_ key: Data) -> String {
        let checksum = Data(SHA256.hash(data: key).prefix(4)); let hex = (key + checksum).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 8).map { start in String(hex.dropFirst(start).prefix(8)) }.joined(separator: "-")
    }
    public static func recoveryKey(_ string: String) throws -> Data {
        let hex = string.filter { !$0.isWhitespace && $0 != "-" }.uppercased(); guard hex.count == 72, hex.allSatisfy({ $0.isHexDigit }) else { throw BudgetError.invalid("Ключ восстановления должен содержать 9 групп по 8 символов.") }
        var bytes = Data(); for offset in stride(from: 0, to: hex.count, by: 2) { guard let b = UInt8(hex.dropFirst(offset).prefix(2), radix: 16) else { throw BudgetError.wrongKey }; bytes.append(b) }
        let key = Data(bytes.prefix(32)); guard Data(bytes.suffix(4)) == Data(SHA256.hash(data: key).prefix(4)) else { throw BudgetError.invalid("Контрольная сумма ключа не совпала. Проверьте все группы.") }; return key
    }
    public static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
