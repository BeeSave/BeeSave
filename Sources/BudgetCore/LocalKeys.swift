import Foundation
import Security
import LocalAuthentication

public enum LocalKeys {
    // Keep the established service and signing identity across the app rename.
    private static let service = "com.mubudget.local.v1"
    public static func keychainEntitled() -> Bool {
        var code: SecCode?; var staticCode: SecStaticCode?; var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return (entitlements["com.apple.application-identifier"] as? String)?.isEmpty == false || (entitlements["keychain-access-groups"] as? [String])?.isEmpty == false
    }
    public static func biometricAvailable() -> Bool { guard keychainEntitled() else { return false }; let c = LAContext(); return c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) }
    private static func query(_ id: UUID, biometric: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString + (biometric ? ".biometric" : ".local"), kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false]
    }
    public static func put(_ key: Data, id: UUID, biometric: Bool) throws {
        guard keychainEntitled() else { throw BudgetError.storage("Для Touch ID и входа без пароля требуется подписанная сборка с правами Keychain. В этой сборке выберите вход паролем.") }
        var q = query(id, biometric: biometric); q[kSecValueData as String] = key
        if biometric {
            var error: Unmanaged<CFError>?
            guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &error) else { throw BudgetError.storage("Не удалось настроить защиту Touch ID.") }
            q[kSecAttrAccessControl as String] = ac
        } else { q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw BudgetError.storage("Keychain не сохранил ключ (код \(status)). Прежний способ входа сохранён; повторите или используйте пароль.") }
    }
    public static func get(id: UUID, biometric: Bool, context: LAContext? = nil) throws -> Data {
        var q = query(id, biometric: biometric); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context { q[kSecUseAuthenticationContext as String] = context }
        else { let c = LAContext(); c.localizedReason = biometric ? "Открыть локальный бюджет" : "Доступ к локальной зашифрованной базе"; c.localizedFallbackTitle = ""; q[kSecUseAuthenticationContext as String] = c }
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let key = result as? Data, key.count == 32 else { throw BudgetError.storage(biometric ? "Touch ID отменён, недоступен или отпечатки изменились. Повторите, используйте пароль или ключ восстановления." : "Локальный ключ Keychain недоступен. Используйте ключ восстановления.") }; return key
    }
    public static func remove(id: UUID, biometric: Bool) { SecItemDelete(query(id, biometric: biometric) as CFDictionary) }
    public static func confirmOwner() async throws {
        let context = LAContext(); guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { throw BudgetError.storage("Системное подтверждение владельца macOS недоступно.") }
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Подтвердить изменение защиты локального бюджета") else { throw BudgetError.wrongKey }
    }
}
