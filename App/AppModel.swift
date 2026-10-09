import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BudgetCore
import BudgetPresentation

enum SectionID: String, CaseIterable, Identifiable {
    case dashboard = "Главная", accounts = "Мои счета", expenses = "Расходы", incomes = "Доходы", budgets = "Бюджет", references = "Справочники", financialCalendar = "Календарь"
    var id: String { rawValue }
    var icon: String { switch self { case .dashboard: "square.grid.2x2"; case .accounts: "wallet.bifold"; case .expenses: "arrow.up.right"; case .incomes: "arrow.down.left"; case .budgets: "chart.pie"; case .references: "books.vertical"; case .financialCalendar: "calendar" } }
}
enum SettingsTask: String, CaseIterable, Identifiable {
    case general = "Общие", appearance = "Внешний вид", access = "Вход и защита", rates = "Валюты и курсы", backups = "Резервные копии", transfer = "Импорт и экспорт", reminders = "Напоминания"
    var id: String { rawValue }
}
struct SheetRoute: Identifiable {
    enum Kind { case account, bank, financialPayment, scheduledPayment, scheduledDetail, operation, reconciliation, category, project, budget, report, reportView, layout, importCSV, restore }
    var id = UUID(); var kind: Kind; var entityID: UUID?; var operationKind = OperationKind.expense; var accountContext: UUID?; var budgetKind = BudgetKind.monthly
}
@MainActor final class AppModel: ObservableObject {
    #if DEBUG && UI_SMOKE
    @Published var previewAppearance: ColorScheme? = nil
    @Published var previewScenario = PreviewScenario.filled
    #endif
    @Published var settingsTask = SettingsTask.general; @Published var showGettingStarted = false; @Published var db: Database?; @Published var bootstrap: Bootstrap?; @Published var section = SectionID.dashboard; @Published var sheet: SheetRoute?; @Published var historyAccount: UUID?; @Published var error: String?; @Published var backupError: String?; @Published var busy = false; @Published var rateBusy = false; @Published var retryAt: Date?; @Published var drilldownTitle = "Операции показателя"; @Published var drilldownFilters = Filters(); @Published var drilldown: [UUID]?; @Published var startupError: String?
    @Published var noticeMessage: AppNotice?
    @Published var rateError: String?
    private var noticeTask: Task<Void, Never>?
    private var dailyBackupTask: Task<Void, Never>?
    private var dailyBackupID = UUID()
    @Published private(set) var dailyBackupBusy = false
    private let noticeWindows = NSHashTable<NSWindow>.weakObjects()
    func registerNoticeWindow(_ window: NSWindow) { noticeWindows.add(window) }
    var notice: String? {
        get { noticeMessage?.text }
        set { if let text = newValue { showNotice(text) } else { noticeTask?.cancel(); noticeMessage = nil } }
    }
    func showNotice(_ text: String, kind: NoticeKind = .information) {
        noticeTask?.cancel()
        let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
        let message = AppNotice(text, kind: kind, duration: voiceOver ? 12 : 4)
        noticeMessage = message
        if voiceOver {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        guard message.transient else { return }
        noticeTask = Task { [weak self] in
            var current = message
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.noticeMessage?.id == message.id else { return }
                let visible = NSApp.isActive && NSApp.keyWindow.map(self.noticeWindows.contains) == true && self.db != nil
                if current.elapse(0.25, token: message.id, visible: visible) { self.noticeMessage = nil; return }
            }
        }
    }
    @Published var financialEvents: [UUID: [FinanceEvent]] = [:]
    @Published var financialDebts: [UUID: DebtSummary] = [:]
    @Published var financialErrors: [UUID: String] = [:]
    @Published var financialBusy = false
    @Published var showScheduledExpenses = false
    @Published var financialNotificationStatus: FinancialNotificationStatus?
    var pendingFinancialRoute: (String, String)?
    var financialTask: Task<Void, Never>?
    var financialCalculationID = UUID()
    let vault: VaultStore; let root: URL; var rateTask: Task<Void, Never>?; private var failures = 0; var lastActivity = Date(); private var sessionHidden = false; private var lastRateAttempt = Date.distantPast
    @Published var updateFrozen = false
    @Published var updateForms = Set<UUID>()
    var confirmUpdatedBudget: (() -> Void)?
    @Published var updateVerificationPending = false
    #if DEBUG && UI_SMOKE && NOTIFICATION_QA
    var notificationQAActive = false
    #endif
    var updateBlocker: String? {
        if busy || rateBusy || dailyBackupBusy { return "Дождитесь завершения записи, резервного копирования или обновления курсов." }
        if sheet != nil || !updateForms.isEmpty { return "Сохраните или закройте открытые формы во всех окнах BeeSave." }
        if NSApplication.shared.modalWindow != nil || NSApplication.shared.windows.contains(where: { $0.attachedSheet != nil }) {
            return "Завершите открытый диалог BeeSave перед установкой обновления."
        }
        if startupError != nil { return "Сначала устраните ошибку открытия бюджета." }
        return nil
    }
    private func requireWritableSession() throws {
        guard !updateFrozen else { throw BudgetError.storage("Дождитесь завершения установки обновления.") }
        guard !updateVerificationPending else {
            throw BudgetError.storage("Не завершена проверка сохранности бюджета после обновления. Откройте «Проверить обновление» в меню BeeSave.")
        }
    }
    init() {
        #if DEBUG && UI_SMOKE
        if true {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("BeeSaveSmoke-" + UUID().uuidString + ".noindex")
            vault = VaultStore(url: root.appendingPathComponent("vault.beesave"))
            let name = ProcessInfo.processInfo.environment["BEESAVE_UI_STATE"] ?? ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-state=") })?.replacingOccurrences(of: "--ui-state=", with: "") ?? "filled"
            loadPreview(PreviewScenario(rawValue: name) ?? .filled)
            #if UPDATE_QA
            prepareUpdateMigrationQA()
            #endif
            installObservers(); return
        }
        #endif
        let location = StorageLocation(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        root = location.directory
        vault = VaultStore(url: location.vault)
        do { try vault.acquire(); if vault.exists { bootstrap = try vault.inspect() } }
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
            if db.settings.lockMinutes > 0, Date().timeIntervalSince(self.lastActivity) >= Double(db.settings.lockMinutes * 60) { self.lock() }
            else if Date().timeIntervalSince(db.settings.lastRateCheck ?? .distantPast) > 3600 { self.refreshRates(automatic: true) }
        } }
    }
    func lock() {
        dailyBackupID = UUID(); dailyBackupTask?.cancel(); dailyBackupTask = nil; dailyBackupBusy = false
        BudgetWindows.hideSensitiveWindows()
        rateError = nil
        cancelFinancialForecasts(); financialEvents = [:]; financialDebts = [:]; financialErrors = [:]; financialNotificationStatus = nil
        rateTask?.cancel(); rateTask = nil; rateBusy = false; sheet = nil; historyAccount = nil; drilldown = nil; showGettingStarted = false; settingsTask = .general; error = nil; notice = nil; backupError = nil; db = nil; vault.close(); sessionHidden = true
    }
    func resumeSession() {
        guard sessionHidden else { return }; sessionHidden = false
    }
    func didUnlock() { dailyBackupID = UUID(); dailyBackupTask?.cancel(); dailyBackupTask = nil; dailyBackupBusy = false; BudgetWindows.sessionUnlocked(); error = nil; db = vault.db; bootstrap = vault.bootstrap; startupError = nil; failures = 0; retryAt = nil; sessionHidden = false; activity(); confirmUpdatedBudget?(); refreshRates(automatic: true); refreshFinancialForecasts() }
    func unlock(password: String) {
        guard !busy else { return }; guard retryAt == nil || Date() >= retryAt! else { error = "Подождите 30 секунд после пяти ошибочных попыток."; return }
        busy = true; defer { busy = false }
        do { try vault.unlock(password: password); didUnlock() }
        catch { self.error = error.localizedDescription; failures += 1; if failures >= 5 { retryAt = Date().addingTimeInterval(30); failures = 0 } }
    }
    func resetPassword(recovery: String, newPassword: String) {
        guard !busy else { return }; guard retryAt == nil || Date() >= retryAt! else { error = "Подождите 30 секунд после пяти ошибочных попыток."; return }
        busy = true; defer { busy = false }
        do { try vault.resetPassword(recovery: recovery, newPassword: newPassword); didUnlock() }
        catch { self.error = error.localizedDescription; failures += 1; if failures >= 5 { retryAt = Date().addingTimeInterval(30); failures = 0 } }
    }
    func setup(currency: String, password: String, recovery: String, confirmed: String, lockMinutes: Int = 5) throws {
        try requireWritableSession()
        guard try VaultCrypto.recoveryKey(recovery) == VaultCrypto.recoveryKey(confirmed) else { throw BudgetError.invalid("Проверочный ввод ключа не совпал.") }
        let key = try VaultCrypto.random(); var database = Database(); database.settings.baseCurrency = currency; database.settings.reportCurrency = currency; database.settings.lockMinutes = lockMinutes
        let b = Bootstrap(databaseID: database.id, password: try VaultCrypto.wrapPassword(key, password: password), recovery: try VaultCrypto.seal(key, key: VaultCrypto.recoveryKey(recovery), context: VaultCrypto.recoveryContext))
        try vault.initialize(db: database, dataKey: key, bootstrap: b); didUnlock(); showGettingStarted = true
    }
    func commit(_ mutation: (inout Database) throws -> Void) throws {
        try requireWritableSession()
        guard !busy else { throw BudgetError.storage("Дождитесь завершения текущей записи.") }; busy = true; defer { busy = false }
        try vault.transaction(mutation); db = vault.db; activity()
        scheduleDailyBackup()
        refreshFinancialForecasts()
    }
    private func scheduleDailyBackup() {
        guard dailyBackupTask == nil, let database = db, database.settings.lastDaily != .today else { return }
        let id = UUID(), folder = backupFolder, now = Date(), day = Day.today
        dailyBackupID = id; dailyBackupBusy = true
        do {
            let snapshot = try vault.snapshot()
            dailyBackupTask = Task { [weak self] in
                do {
                    // Let the saved change finish its first layout/paint before
                    // starting another large encode/decode on the same machine.
                    try await Task.sleep(for: .milliseconds(250))
                    let worker = Task.detached(priority: .utility) {
                        try Task.checkCancellation()
                        let scope = folder.startAccessingSecurityScopedResource()
                        defer { if scope { folder.stopAccessingSecurityScopedResource() } }
                        _ = try Backups.write(snapshot: snapshot, folder: folder, kind: "daily", now: now)
                        try Task.checkCancellation()
                    }
                    try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    let completedAt = Date()
                    while !Task.isCancelled {
                        guard let self, self.dailyBackupID == id, self.db?.id == database.id else { return }
                        guard self.backupFolder == folder else { break }
                        let latest = try self.vault.snapshot()
                        let preparation = Task.detached(priority: .utility) {
                            try Task.checkCancellation()
                            return try latest.recordingDailyBackup(day: day, completedAt: completedAt)
                        }
                        let prepared = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
                        try Task.checkCancellation()
                        guard self.dailyBackupID == id, self.db?.id == database.id else { return }
                        guard self.backupFolder == folder else { break }
                        if try self.vault.applyBackupStamp(prepared) {
                            self.db = self.vault.db; self.backupError = nil
                            self.refreshFinancialForecasts()
                            break
                        }
                        await Task.yield()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if let self, self.dailyBackupID == id {
                        self.backupError = "Автокопия не создана: " + error.localizedDescription
                    }
                }
                guard let self, self.dailyBackupID == id else { return }
                self.dailyBackupTask = nil; self.dailyBackupBusy = false
                if self.db?.id == database.id, self.backupFolder != folder { self.scheduleDailyBackup() }
            }
        } catch {
            dailyBackupBusy = false; backupError = "Автокопия не создана: " + error.localizedDescription
        }
    }
    func waitForDailyBackup() async {
        while let task = dailyBackupTask { await task.value }
    }
    func perform(_ mutation: (inout Database) throws -> Void) { do { try commit(mutation) } catch { self.error = error.localizedDescription } }
    func newOperation(_ kind: OperationKind, account: UUID? = nil) { guard !updateFrozen, !updateVerificationPending else { return }; sheet = SheetRoute(kind: .operation, operationKind: kind, accountContext: account ?? historyAccount) }
    func openHistory(_ id: UUID) { historyAccount = id; section = .accounts }
    func showOperations(_ ids: [UUID], title: String = "Операции показателя", filters: Filters = Filters()) { drilldownTitle = title; drilldownFilters = filters; drilldown = ids }
    func refreshRates(automatic: Bool = false) {
        guard !updateFrozen, !updateVerificationPending else { return }
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
                try Task.checkCancellation(); guard self.db != nil, !self.updateFrozen, !self.updateVerificationPending else { return }
                try self.vault.transaction { db in for r in values { db.rates.removeAll { $0.base == r.base && $0.quote == r.quote && $0.date == r.date && $0.provider == r.provider }; db.rates.append(r) }; db.settings.lastRateCheck = Date() }
                self.db = self.vault.db; self.refreshFinancialForecasts(); self.rateError = nil; self.showNotice("Курсы обновлены", kind: .success)
            } catch is CancellationError {} catch { if self.db != nil { let message = "Курсы не обновлены: " + error.localizedDescription + " Кеш сохранён; доступен ручной курс."; self.rateError = message; self.showNotice(message, kind: .warning) } }
        }
    }
    func exportCSV(selection: [BudgetCore.Operation]? = nil, filters: Filters? = nil) {
        guard !updateFrozen else { return }
        guard let db else { return }; let currentFilters = filters ?? db.settings.dashboardFilters
        let current = selection ?? Reports.selected(db, filters: currentFilters)
        let alert = NSAlert(); alert.messageText = "Экспорт операций в CSV"
        alert.informativeText = "Выборка: \(CalendarDays.range(currentFilters)), \(current.count) записей. Счета: \(currentFilters.accounts.count == 0 ? "все" : String(currentFilters.accounts.count)); категории: \(currentFilters.categories.count == 0 ? "все" : String(currentFilters.categories.count)).\nCSV сохраняется открытым текстом без шифрования."
        alert.addButton(withTitle: "Текущая выборка · \(current.count)"); alert.addButton(withTitle: "Все операции · \(db.operations.count)"); alert.addButton(withTitle: "Отмена")
        let response = alert.runModal(); guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        var exported = response == .alertFirstButtonReturn ? current : db.operations
        let selectedIDs = Set(exported.map(\.id))
        let incomplete = db.financeData.groups.filter { !selectedIDs.isDisjoint(with: $0.operationIDs) && !Set($0.operationIDs).isSubset(of: selectedIDs) }
        if !incomplete.isEmpty {
            let missing = Set(incomplete.flatMap(\.operationIDs)).subtracting(selectedIDs)
            let rows = db.operations.filter { missing.contains($0.id) }
            let review = NSAlert(); review.messageText = "В выборке есть части финансовых платежей"
            review.informativeText = "Связанные записи вне фильтра: \(rows.count).\n" + rows.prefix(20).map { "\($0.date) · \($0.kind.title) · " + ((try? db.account($0.accountID).name) ?? "") + " · " + BeeFormat.money($0.amount, currency: (try? db.account($0.accountID).currency) ?? "RUB") }.joined(separator: "\n")
            review.addButton(withTitle: "Включить связанные записи"); review.addButton(withTitle: "Исключить неполные группы"); review.addButton(withTitle: "Отмена")
            switch review.runModal() { case .alertFirstButtonReturn: exported += rows; case .alertSecondButtonReturn: let removed = Set(incomplete.flatMap(\.operationIDs)); exported.removeAll { removed.contains($0.id) }; default: return }
        }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "BeeSave-\(Day.today).csv"; guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let bytes = try CSVCodec.export(exported, db: db); try bytes.write(to: url, options: .atomic); notice = "Экспорт сохранён: \(url.lastPathComponent)" } catch { self.error = "Экспорт не сохранён: " + error.localizedDescription }
    }
    func manualBackup() {
        guard !updateFrozen, !updateVerificationPending else { return }
        guard let databaseID = db?.id else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "BeeSave-\(Day.today).mubak"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self.requireWritableSession()
                guard self.db?.id == databaseID else { throw BudgetError.conflict("Бюджет изменился. Повторите сохранение копии.") }
                try self.vault.backup(to: url); try self.vault.transaction { $0.settings.lastBackup = Date() }
                self.db = self.vault.db; self.notice = "Полная зашифрованная копия проверена и сохранена."
            } catch { self.error = error.localizedDescription }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
    func changeBackupFolder() {
        guard !updateFrozen, !updateVerificationPending else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil); try commit { $0.settings.backupPath = folder.path; $0.settings.backupBookmark = bookmark; $0.settings.lastDaily = nil }; backupError = nil } catch { self.error = error.localizedDescription }
    }
    func changePassword(current: String, useRecovery: Bool, newPassword: String) async throws {
        try requireWritableSession()
        try Task.checkCancellation()
        try vault.changePassword(current: current, useRecovery: useRecovery, newPassword: newPassword)
        bootstrap = vault.bootstrap
    }
    func importPreview(_ preview: ImportPreview) throws {
        try requireWritableSession()
        guard preview.canCommit else { throw BudgetError.invalid("Исправьте или явно исключите ошибочные строки.") }
        guard let currentDB = db, currentDB.id == preview.database.id, (currentDB.revision ?? 0) == preview.sourceRevision else { throw BudgetError.conflict("Данные изменились после предпросмотра. Обновите проверку перед импортом.") }
        let folder = backupFolder; let scope = folder.startAccessingSecurityScopedResource(); defer { if scope { folder.stopAccessingSecurityScopedResource() } }
        _ = try Backups.beforeMassChange(store: vault, folder: folder)
        try commit { try CSVImporter.commit(preview, into: &$0) }
        notice = "Импорт: добавлено \(preview.added.count), пропущено \(preview.skipped), исключено \(preview.excluded)."
    }
    func restore(_ preview: (Database, VaultFile, Data), newPassword: String) throws {
        try requireWritableSession()
        guard newPassword.count >= 12 else { throw BudgetError.invalid("Для нового локального входа задайте пароль не менее 12 символов.") }
        let folder = backupFolder; let scope = folder.startAccessingSecurityScopedResource(); defer { if scope { folder.stopAccessingSecurityScopedResource() } }
        let safety = vault.exists ? try Backups.write(store: vault, folder: folder, kind: "service") : nil
        var next = preview.1.bootstrap; next.password = try VaultCrypto.wrapPassword(preview.2, password: newPassword); next.touchID = false; next.localKeyID = UUID(); var restored = preview.0; restored.settings.backupBookmark = nil; restored.settings.backupPath = nil; restored.settings.lastDaily = nil
        try vault.restore(database: restored, dataKey: preview.2, bootstrap: next, safetyCopy: safety)
        didUnlock(); notice = "Копия восстановлена. Используйте заданный пароль для входа."
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
                try vault.initialize(db: sample, dataKey: key, bootstrap: b); BudgetWindows.sessionUnlocked(); db = vault.db; bootstrap = b
            }
            notice = "Тестовое окно · вымышленные данные · отдельная временная база"; refreshFinancialForecasts()
        } catch { startupError = error.localizedDescription }
    }
}
#endif
