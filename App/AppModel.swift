import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BudgetCore
import BudgetPresentation

enum SectionID: String, CaseIterable, Identifiable {
    case dashboard = "Главная", accounts = "Мои счета", expenses = "Расходы", incomes = "Доходы", budgets = "Бюджет", references = "Справочники"
    var id: String { rawValue }
    var icon: String { switch self { case .dashboard: "square.grid.2x2"; case .accounts: "wallet.bifold"; case .expenses: "arrow.up.right"; case .incomes: "arrow.down.left"; case .budgets: "chart.pie"; case .references: "books.vertical" } }
}
enum SettingsTask: String, CaseIterable, Identifiable {
    case general = "Общие", access = "Вход и защита", rates = "Валюты и курсы", backups = "Резервные копии", transfer = "Импорт и экспорт"
    var id: String { rawValue }
}
struct SheetRoute: Identifiable {
    enum Kind { case account, operation, reconciliation, category, project, budget, report, reportView, layout, importCSV, restore }
    var id = UUID(); var kind: Kind; var entityID: UUID?; var operationKind = OperationKind.expense; var accountContext: UUID?; var budgetKind = BudgetKind.monthly
}
@MainActor final class AppModel: ObservableObject {
    #if DEBUG && UI_SMOKE
    @Published var previewAppearance: ColorScheme? = nil
    @Published var previewScenario = PreviewScenario.filled
    #endif
    @Published var settingsTask = SettingsTask.general; @Published var showGettingStarted = false; @Published var db: Database?; @Published var bootstrap: Bootstrap?; @Published var section = SectionID.dashboard; @Published var sheet: SheetRoute?; @Published var historyAccount: UUID?; @Published var error: String?; @Published var backupError: String?; @Published var notice: String?; @Published var busy = false; @Published var rateBusy = false; @Published var retryAt: Date?; @Published var drilldownTitle = "Операции показателя"; @Published var drilldownFilters = Filters(); @Published var drilldown: [UUID]?; @Published var startupError: String?
    let vault: VaultStore; let root: URL; var rateTask: Task<Void, Never>?; private var failures = 0; var lastActivity = Date(); private var sessionHidden = false; private var lastRateAttempt = Date.distantPast
    init() {
        #if DEBUG && UI_SMOKE
        if true {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("BeeSaveSmoke-" + UUID().uuidString + ".noindex")
            vault = VaultStore(url: root.appendingPathComponent("vault.beesave"))
            let name = ProcessInfo.processInfo.environment["BEESAVE_UI_STATE"] ?? ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-state=") })?.replacingOccurrences(of: "--ui-state=", with: "") ?? "filled"
            loadPreview(PreviewScenario(rawValue: name) ?? .filled)
            installObservers(); return
        }
        #endif
        let location = StorageLocation(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        root = location.directory
        vault = VaultStore(url: location.vault)
        do { try vault.acquire(); if vault.exists { bootstrap = try vault.inspect(); if bootstrap?.requiresAuthentication == false { try vault.unlock(key: LocalKeys.get(id: bootstrap!.localKeyID, biometric: false)); db = vault.db } } }
        catch { startupError = error.localizedDescription }
        installObservers()
    }
    var backupFolder: URL {
        var stale = false
        if let bookmark = db?.settings.backupBookmark, let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) { return resolved }
        return root.appendingPathComponent("Backups.noindex", isDirectory: true)
    }
    func activity() { lastActivity = Date() }
    private func installObservers() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in Task { @MainActor in self?.activity() }; return event }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } }
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } }
        workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.resumeSession() } }
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } }
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.resumeSession() } }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self, let db = self.db else { return }
            if self.bootstrap?.requiresAuthentication == true, db.settings.lockMinutes > 0, Date().timeIntervalSince(self.lastActivity) >= Double(db.settings.lockMinutes * 60) { self.lock() }
            else if Date().timeIntervalSince(db.settings.lastRateCheck ?? .distantPast) > 3600 { self.refreshRates(automatic: true) }
        } }
    }
    func lock() {
        rateTask?.cancel(); rateTask = nil; rateBusy = false; sheet = nil; historyAccount = nil; drilldown = nil; showGettingStarted = false; settingsTask = .general; error = nil; notice = nil; backupError = nil; db = nil; vault.close(); sessionHidden = true
    }
    func resumeSession() {
        guard sessionHidden else { return }; sessionHidden = false
        if bootstrap?.requiresAuthentication == false { do { try vault.unlock(key: LocalKeys.get(id: bootstrap!.localKeyID, biometric: false)); didUnlock() } catch { self.error = error.localizedDescription } }
    }
    func didUnlock() { db = vault.db; bootstrap = vault.bootstrap; startupError = nil; failures = 0; retryAt = nil; sessionHidden = false; activity(); refreshRates(automatic: true) }
    func unlock(password: String? = nil, recovery: String? = nil, biometric: Bool = false) {
        guard !busy else { return }; guard retryAt == nil || Date() >= retryAt! else { error = "Подождите 30 секунд после пяти ошибочных попыток."; return }
        busy = true; defer { busy = false }
        do { if biometric { guard bootstrap?.touchID == true else { throw BudgetError.invalid("Touch ID отключён.") }; try vault.unlock(key: LocalKeys.get(id: bootstrap!.localKeyID, biometric: true)) } else if let recovery { try vault.unlock(recovery: recovery) } else { try vault.unlock(password: password ?? "") }; didUnlock() }
        catch { self.error = error.localizedDescription; failures += 1; if failures >= 5 { retryAt = Date().addingTimeInterval(30); failures = 0 } }
    }
    func setup(currency: String, password: String, touchID: Bool, recovery: String, confirmed: String, lockMinutes: Int = 5) throws {
        guard try VaultCrypto.recoveryKey(recovery) == VaultCrypto.recoveryKey(confirmed) else { throw BudgetError.invalid("Проверочный ввод ключа не совпал.") }
        let key = try VaultCrypto.random(); var database = Database(); database.settings.baseCurrency = currency; database.settings.reportCurrency = currency; database.settings.lockMinutes = lockMinutes
        var b = Bootstrap(databaseID: database.id, password: password.isEmpty ? nil : try VaultCrypto.wrapPassword(key, password: password), recovery: try VaultCrypto.seal(key, key: VaultCrypto.recoveryKey(recovery), context: VaultCrypto.recoveryContext), touchID: touchID)
        b.localKeyID = UUID()
        do {
            if touchID { guard LocalKeys.biometricAvailable() else { throw BudgetError.invalid("Touch ID недоступен на этом Mac.") }; try LocalKeys.put(key, id: b.localKeyID, biometric: true); guard try LocalKeys.get(id: b.localKeyID, biometric: true) == key else { throw BudgetError.wrongKey } }
            if !b.requiresAuthentication { try LocalKeys.put(key, id: b.localKeyID, biometric: false); guard try LocalKeys.get(id: b.localKeyID, biometric: false) == key else { throw BudgetError.wrongKey } }
            try vault.initialize(db: database, dataKey: key, bootstrap: b); didUnlock(); showGettingStarted = true
        } catch { LocalKeys.remove(id: b.localKeyID, biometric: true); LocalKeys.remove(id: b.localKeyID, biometric: false); throw error }
    }
    func commit(_ mutation: (inout Database) throws -> Void) throws {
        guard !busy else { throw BudgetError.storage("Дождитесь завершения текущей записи.") }; busy = true; defer { busy = false }
        try vault.transaction(mutation); db = vault.db; activity()
        let folder = backupFolder; let scope = folder.startAccessingSecurityScopedResource(); defer { if scope { folder.stopAccessingSecurityScopedResource() } }
        do { try Backups.daily(store: vault, folder: folder); db = vault.db; backupError = nil } catch { backupError = "Автокопия не создана: " + error.localizedDescription }
    }
    func perform(_ mutation: (inout Database) throws -> Void) { do { try commit(mutation) } catch { self.error = error.localizedDescription } }
    func newOperation(_ kind: OperationKind, account: UUID? = nil) { sheet = SheetRoute(kind: .operation, operationKind: kind, accountContext: account ?? historyAccount) }
    func openHistory(_ id: UUID) { historyAccount = id; section = .accounts }
    func showOperations(_ ids: [UUID], title: String = "Операции показателя", filters: Filters = Filters()) { drilldownTitle = title; drilldownFilters = filters; drilldown = ids }
    func refreshRates(automatic: Bool = false) {
        #if DEBUG && UI_SMOKE
        if automatic { return }
        #endif
        guard let database = db, !rateBusy else { return }
        if automatic && (Date().timeIntervalSince(database.settings.lastRateCheck ?? .distantPast) < 3600 || Date().timeIntervalSince(lastRateAttempt) < 3600) { return }
        rateBusy = true; lastRateAttempt = Date()
        rateTask = Task { [weak self] in
            guard let self else { return }; defer { self.rateBusy = false }
            let client = RateClient(); let base = database.settings.baseCurrency
            do {
                var values = (try? await client.cbr()) ?? []
                for code in Set(database.accounts.map(\.currency) + ["USD", "GBP", base]) where code != base {
                    try Task.checkCancellation(); if try Reports.rate(from: code, to: base, rates: values, on: .today) == nil { values.append(try await client.fetch(base: code, quote: base)) }
                }
                try Task.checkCancellation(); guard self.db != nil else { return }
                try self.vault.transaction { db in for r in values { db.rates.removeAll { $0.base == r.base && $0.quote == r.quote && $0.date == r.date && $0.provider == r.provider }; db.rates.append(r) }; db.settings.lastRateCheck = Date() }
                self.db = self.vault.db; self.notice = "Справочные курсы обновлены. Даты и источники доступны в настройках."
            } catch is CancellationError {} catch { if self.db != nil { self.notice = "Курсы не обновлены: " + error.localizedDescription + " Кеш сохранён; доступен ручной курс." } }
        }
    }
    func exportCSV(selection: [BudgetCore.Operation]? = nil, filters: Filters? = nil) {
        guard let db else { return }; let currentFilters = filters ?? db.settings.dashboardFilters
        let current = selection ?? Reports.selected(db, filters: currentFilters)
        let alert = NSAlert(); alert.messageText = "Экспорт операций в CSV"
        alert.informativeText = "Выборка: \(CalendarDays.range(currentFilters)), \(current.count) записей. Счета: \(currentFilters.accounts.count == 0 ? "все" : String(currentFilters.accounts.count)); категории: \(currentFilters.categories.count == 0 ? "все" : String(currentFilters.categories.count)).\nCSV сохраняется открытым текстом без шифрования."
        alert.addButton(withTitle: "Текущая выборка · \(current.count)"); alert.addButton(withTitle: "Все операции · \(db.operations.count)"); alert.addButton(withTitle: "Отмена")
        let response = alert.runModal(); guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        let exported = response == .alertFirstButtonReturn ? current : db.operations
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "BeeSave-\(Day.today).csv"; guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let bytes = try CSVCodec.export(exported, db: db); try bytes.write(to: url, options: .atomic); notice = "Экспорт сохранён: \(url.lastPathComponent)" } catch { self.error = "Экспорт не сохранён. Проверьте место и права записи." }
    }
    func manualBackup() {
        guard db != nil else { return }; let panel = NSSavePanel(); panel.nameFieldStringValue = "BeeSave-\(Day.today).mubak"; guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try vault.backup(to: url); try vault.transaction { $0.settings.lastBackup = Date() }; db = vault.db; notice = "Полная зашифрованная копия проверена и сохранена." } catch { self.error = error.localizedDescription }
    }
    func changeBackupFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil); try commit { $0.settings.backupPath = folder.path; $0.settings.backupBookmark = bookmark; $0.settings.lastDaily = nil }; backupError = nil } catch { self.error = error.localizedDescription }
    }
    func changeAccess(current: String, useRecovery: Bool, passwordEnabled: Bool, newPassword: String, touchID: Bool) async throws {
        guard let old = bootstrap else { throw BudgetError.locked }
        if useRecovery { try vault.verifyRecovery(current) }
        else if old.password != nil && !current.isEmpty { try vault.verifyPassword(current) }
        else if old.touchID { let key = try LocalKeys.get(id: old.localKeyID, biometric: true); guard try vault.withKey({ $0 == key }) else { throw BudgetError.wrongKey } }
        else if !old.requiresAuthentication { try await LocalKeys.confirmOwner() }
        else { throw BudgetError.invalid("Подтвердите текущий пароль или ключ восстановления.") }
        try Task.checkCancellation()
        var next = old; next.localKeyID = UUID(); next.touchID = touchID
        next.password = passwordEnabled ? (newPassword.isEmpty ? old.password : try vault.withKey { try VaultCrypto.wrapPassword($0, password: newPassword) }) : nil
        guard !passwordEnabled || next.password != nil else { throw BudgetError.invalid("Введите новый пароль.") }
        do {
            try vault.withKey { key in
                if touchID { guard LocalKeys.biometricAvailable() else { throw BudgetError.invalid("Touch ID недоступен.") }; try LocalKeys.put(key, id: next.localKeyID, biometric: true); guard try LocalKeys.get(id: next.localKeyID, biometric: true) == key else { throw BudgetError.wrongKey } }
                if !next.requiresAuthentication { try LocalKeys.put(key, id: next.localKeyID, biometric: false); guard try LocalKeys.get(id: next.localKeyID, biometric: false) == key else { throw BudgetError.wrongKey } }
            }
            try Task.checkCancellation()
            try vault.changeBootstrap(next); bootstrap = next; LocalKeys.remove(id: old.localKeyID, biometric: true); LocalKeys.remove(id: old.localKeyID, biometric: false)
        } catch { LocalKeys.remove(id: next.localKeyID, biometric: true); LocalKeys.remove(id: next.localKeyID, biometric: false); throw error }
    }
    func importPreview(_ preview: ImportPreview) throws {
        guard preview.canCommit else { throw BudgetError.invalid("Исправьте или явно исключите ошибочные строки.") }
        guard let currentDB = db, currentDB.id == preview.database.id, (currentDB.revision ?? 0) == preview.sourceRevision else { throw BudgetError.conflict("Данные изменились после предпросмотра. Обновите проверку перед импортом.") }
        let folder = backupFolder; let scope = folder.startAccessingSecurityScopedResource(); defer { if scope { folder.stopAccessingSecurityScopedResource() } }
        _ = try Backups.beforeMassChange(store: vault, folder: folder)
        try commit { try CSVImporter.commit(preview, into: &$0) }
        notice = "Импорт: добавлено \(preview.added.count), пропущено \(preview.skipped), исключено \(preview.excluded)."
    }
    func restore(_ preview: (Database, VaultFile, Data), newPassword: String) throws {
        guard newPassword.count >= 12 else { throw BudgetError.invalid("Для нового локального входа задайте пароль не менее 12 символов.") }
        let folder = backupFolder; let scope = folder.startAccessingSecurityScopedResource(); defer { if scope { folder.stopAccessingSecurityScopedResource() } }
        let safety = vault.exists ? try Backups.write(store: vault, folder: folder, kind: "service") : nil
        var next = preview.1.bootstrap; next.password = try VaultCrypto.wrapPassword(preview.2, password: newPassword); next.touchID = false; next.localKeyID = UUID(); var restored = preview.0; restored.settings.backupBookmark = nil; restored.settings.backupPath = nil; restored.settings.lastDaily = nil
        let old = bootstrap; try vault.restore(database: restored, dataKey: preview.2, bootstrap: next, safetyCopy: safety)
        if let old { LocalKeys.remove(id: old.localKeyID, biometric: true); LocalKeys.remove(id: old.localKeyID, biometric: false) }; didUnlock(); notice = "Копия восстановлена. Touch ID настраивается заново на этом Mac."
    }
}

#if DEBUG && UI_SMOKE
extension AppModel {
    func loadPreview(_ scenario: PreviewScenario) {
        guard root.lastPathComponent.hasPrefix("BeeSaveSmoke-") else { return }
        lock(); bootstrap = nil; startupError = nil; previewScenario = scenario
        do {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            try vault.acquire()
            if scenario != .new {
                let sample = try PreviewFixtures.database(scenario); let key = try VaultCrypto.random(); let recovery = try VaultCrypto.random()
                let b = Bootstrap(databaseID: sample.id, password: try VaultCrypto.wrapPassword(key, password: "UI fixture password only"), recovery: try VaultCrypto.seal(key, key: recovery, context: VaultCrypto.recoveryContext))
                try vault.initialize(db: sample, dataKey: key, bootstrap: b); db = vault.db; bootstrap = b
            }
            notice = "Тестовое окно · вымышленные данные · отдельная временная база"
        } catch { startupError = error.localizedDescription }
    }
}
#endif
