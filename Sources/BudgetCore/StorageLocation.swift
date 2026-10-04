import Foundation

/// Keep opening an existing vault in place so both app names share the same lock.
/// Fresh installations use the BeeSave directory and filename.
public struct StorageLocation: Equatable, Sendable {
    public let directory: URL
    public let vault: URL

    public init(applicationSupport: URL) {
        let current = applicationSupport.appendingPathComponent("BeeSave.noindex", isDirectory: true)
        let currentVault = current.appendingPathComponent("vault.beesave")
        let legacy = applicationSupport.appendingPathComponent("MuBudget.noindex", isDirectory: true)
        let legacyVault = legacy.appendingPathComponent("vault.mubudget")
        if !FileManager.default.fileExists(atPath: currentVault.path),
           FileManager.default.fileExists(atPath: legacyVault.path) {
            directory = legacy
            vault = legacyVault
        } else {
            directory = current
            vault = currentVault
        }
    }
}
