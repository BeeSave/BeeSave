import Foundation

public enum Backups {
    public static func write(store: VaultStore, folder: URL, kind: String, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = kind == "daily" ? "daily-\(Day.local(now)).mubak" : "service-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString).mubak"
        let url = folder.appendingPathComponent(name); try store.backup(to: url)
        // Rotate only the application's own daily/service files after the new copy was verified.
        let prefix = kind == "daily" ? "daily-" : "service-"; let limit = kind == "daily" ? 30 : 10
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]).filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "mubak" }.sorted { a, b in (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast > (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
        for old in files.dropFirst(limit) where old != url { try FileManager.default.removeItem(at: old) }; return url
    }
    public static func daily(store: VaultStore, folder: URL) throws {
        guard store.db?.settings.lastDaily != .today else { return }
        _ = try write(store: store, folder: folder, kind: "daily")
        try store.transaction { $0.settings.lastDaily = .today; $0.settings.lastBackup = Date() }
    }
    public static func beforeMassChange(store: VaultStore, folder: URL) throws -> URL? {
        guard let db = store.db else { throw BudgetError.locked }
        guard !db.accounts.isEmpty || !db.operations.isEmpty || !db.budgets.isEmpty || !db.reports.isEmpty || !db.projects.isEmpty || db.categories.contains(where: { !$0.system }) || !db.imports.isEmpty || !(db.financeData.scheduledPayments ?? []).isEmpty || !db.financeData.banks.isEmpty || !db.financeData.calendars.isEmpty else { return nil }
        return try write(store: store, folder: folder, kind: "service")
    }
}
