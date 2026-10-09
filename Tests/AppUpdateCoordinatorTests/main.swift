import AppKit
import BudgetCore
import BudgetPresentation

private actor ReleaseGate {
    private var first: CheckedContinuation<Data, Never>?
    private var count = 0
    let metadata: Data
    let release: Data
    init() throws {
        let prefix = "https://github.com/BeeSave/BeeSave/releases/download/v2.0.0/"
        let names = ["latest.json", "appcast.xml", "BeeSave-macos-arm64.zip", "BeeSave-macos-arm64.zip.sha256", "BeeSave-macos-arm64.dmg", "BeeSave-macos-arm64.dmg.sha256"]
        release = try JSONSerialization.data(withJSONObject: ["tag_name": "v2.0.0", "draft": false, "prerelease": false, "assets": names.map { ["name": $0, "browser_download_url": prefix + $0] }])
        metadata = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "version": "2.0.0", "build": 7, "minimum_macos": "26.0", "architecture": "arm64", "repository": "BeeSave/BeeSave", "tag": "v2.0.0", "asset_url": prefix + "BeeSave-macos-arm64.zip", "sha256": String(repeating: "a", count: 64)])
    }
    func data(_ url: URL) async -> Data {
        if url != AppUpdateURLs.latest { return metadata }
        count += 1
        if count == 1 { return await withCheckedContinuation { first = $0 } }
        return release
    }
    var waiting: Bool { first != nil }
    func finishLate() { first?.resume(returning: release); first = nil }
}
private struct Transport: AppUpdateTransport {
    let gate: ReleaseGate
    func data(from url: URL, limit: Int) async throws -> Data { await gate.data(url) }
    func download(from url: URL, to file: URL, limit: Int, progress: @escaping @Sendable (Double?) -> Void) async throws { throw AppUpdateError.invalidMetadata }
}

@main struct CoordinatorTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            if !condition { failures += 1; print("FAIL: " + name) } else { print("PASS: " + name) }
        }
        let appearanceDomain = "com.beesave.appearance-test." + UUID().uuidString
        let appearanceDefaults = UserDefaults(suiteName: appearanceDomain)!
        defer { appearanceDefaults.removePersistentDomain(forName: appearanceDomain) }
        let appearance = AppearanceStore(defaults: appearanceDefaults)
        appearance.update { $0.textPercent = 160; $0.theme = .midnight }
        check(AppearanceStore(defaults: appearanceDefaults).preferences == appearance.preferences,
              "installation appearance survives a new store without opening a budget")
        let retained = appearance.preferences
        appearance.update { $0.textPercent = 200 }
        check(appearance.preferences == retained, "invalid font scale cannot be persisted")
        appearance.update { $0.custom.text = $0.custom.surface; $0.theme = .custom }
        check(appearance.preferences == retained, "unreadable custom theme cannot be persisted")
        appearance.update { $0.custom = .preset(.sepia); $0.theme = .custom }
        appearance.update { $0.theme = .midnight }
        check(appearance.preferences.custom == .preset(.sepia), "switching a preset preserves the last custom palette")
        appearance.reset()
        check(appearance.preferences == AppearancePreferences(), "appearance reset restores safe defaults")
        appearanceDefaults.set(Data("broken".utf8), forKey: "BeeSave.appearance.v1")
        check(AppearanceStore(defaults: appearanceDefaults).preferences == AppearancePreferences(), "corrupt installation preferences cannot block startup")
        func wait(_ condition: @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let budgetWindow = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        let otherBudgetWindow = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        let settingsWindow = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        BudgetWindows.sessionUnlocked()
        BudgetWindows.register(budgetWindow); BudgetWindows.register(otherBudgetWindow)
        check(BudgetWindows.preferred(ordered: [settingsWindow, budgetWindow, otherBudgetWindow], key: settingsWindow) === budgetWindow,
              "notification selects the budget window over foreground settings")
        check(BudgetWindows.preferred(ordered: [budgetWindow, otherBudgetWindow], key: otherBudgetWindow) === otherBudgetWindow,
              "notification preserves the active budget window")
        let accessWindow = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        BudgetWindows.register(accessWindow, role: .access)
        BudgetWindows.hideSensitiveWindows()
        check(BudgetWindows.preferred(ordered: [budgetWindow, accessWindow], key: budgetWindow) === accessWindow,
              "locked session never raises a registered workspace window")
        BudgetWindows.sessionUnlocked()
        check(BudgetWindows.preferred(ordered: [accessWindow, budgetWindow], key: accessWindow) === budgetWindow,
              "unlocked session never raises a stale access window")
        BudgetWindows.unregister(accessWindow)
        BudgetWindows.unregister(budgetWindow); BudgetWindows.unregister(otherBudgetWindow)
        check(BudgetWindows.preferred(ordered: [settingsWindow, budgetWindow], key: settingsWindow) == nil,
              "notification does not select unrelated or detached windows")
        let model = AppModel()
        model.setDashboardCurrencies(["USD", "GBP", "EUR", "JPY", "CHF"])
        check(model.db?.settings.selectedDashboardCurrencies.count == 5, "dashboard selection is saved through the real encrypted model")
        let currencyBytes = try Data(contentsOf: model.vault.url)
        model.setDashboardCurrencies(["USD", "GBP", "EUR", "JPY", "CHF", "AUD"])
        check(try Data(contentsOf: model.vault.url) == currencyBytes && model.error != nil, "sixth currency is rejected without writing the vault")
        model.error = nil
        model.setDashboardCurrencies(["RUB"])
        check(try Data(contentsOf: model.vault.url) == currencyBytes && model.error != nil, "base currency is rejected without writing the vault")
        model.error = nil
        model.setBaseCurrency("USD")
        check(model.db?.settings.selectedDashboardCurrencies == ["GBP", "EUR", "JPY", "CHF"], "changing base removes its selected rate and preserves other choices")
        model.setBaseCurrency("RUB")
        check(model.db?.settings.selectedDashboardCurrencies == ["GBP", "EUR", "JPY", "CHF"], "removed base rate is not silently restored")
        model.setDashboardCurrencies([])
        check(model.db?.settings.selectedDashboardCurrencies == [], "explicit empty selection remains hidden")
        let emptyCurrencies = model.db
        model.vault.beforeWrite = { throw BudgetError.storage("Fictional settings write failure") }
        model.setDashboardCurrencies(["USD"])
        check(model.db == emptyCurrencies && model.error != nil, "failed settings write preserves prior selection")
        model.vault.beforeWrite = nil; model.error = nil
        model.setBaseCurrency("USD")
        check(model.db?.settings.baseCurrency == "USD" && model.db?.accounts.last?.currency == "USD", "base currency changes without changing account currencies")
        model.loadPreview(.filled)
        try model.commit { $0.settings.reportCurrency = "GBP" }
        let homeReport = standardReport(metric: .expense, grouping: .category, filters: model.db!.settings.dashboardFilters, db: model.db!)
        let homeTotal = try Reports.total(Reports.rows(homeReport, db: model.db!))
        check(homeReport.currency == "RUB" && homeTotal.known == 128_000, "Home summary uses base currency despite a different legacy report currency")
        model.showOperations(model.db!.operations.filter { $0.kind == .expense }.map(\.id), title: "Home expenses", currency: model.db!.settings.baseCurrency)
        check(model.drilldownCurrency == "RUB", "Home detail carries its own valuation currency")
        model.drilldown = nil
        var savedEUR = Report(name: "Fictional EUR report"); savedEUR.currency = "EUR"
        try model.commit { db in db.reports.append(savedEUR); db.budgets[0].currency = "GBP" }
        let retainedOperations = model.db!.operations
        let retainedGBPPlan = model.db!.budgets[0]
        model.setBaseCurrency("USD")
        check(standardReport(metric: .expense, grouping: .category, filters: model.db!.settings.dashboardFilters, db: model.db!).currency == "USD", "Home summary follows the new base currency")
        check(model.db!.reports.last == savedEUR && model.db!.budgets[0] == retainedGBPPlan && model.db!.operations == retainedOperations,
              "base change preserves saved EUR report, GBP plan and historical operation snapshots")
        model.setBaseCurrency("RUB")
        await model.waitForDailyBackup()
        let rateCache = model.db?.rates
        let rateCheck = model.db?.settings.lastRateCheck
        model.notice = nil
        model.refreshRates()
        check(model.rateBusy, "manual rate update exposes a loading state")
        let cancelledRateTask = model.rateTask
        cancelledRateTask?.cancel()
        await cancelledRateTask?.value
        check(!model.rateBusy && model.db?.rates == rateCache && model.db?.settings.lastRateCheck == rateCheck && model.notice == nil,
              "cancelled rate update retains cache and cannot report success")
        let raw = try Data(contentsOf: model.vault.url)
        let gate = try ReleaseGate()
        let updater = InstallUpdateManager(client: AppUpdateClient(transport: Transport(gate: gate)))
        updater.attach(model)
        updater.check()
        while !(await gate.waiting) { await Task.yield() }
        updater.cancel()
        check(updater.state == .cancelled, "cancel check")
        updater.check()
        try await wait { if case .available = updater.state { return true }; return false }
        check({ if case .available(let release) = updater.state { return release.manifest.version == "2.0.0" }; return false }(), "retry after cancellation")
        let beforeLate = updater.state
        await gate.finishLate()
        try await Task.sleep(nanoseconds: 50_000_000)
        check(updater.state == beforeLate, "late result cannot replace newer cycle")
        let editor = UUID(); model.updateForms.insert(editor)
        updater.install()
        check({ if case .waiting = updater.state { return true }; return false }(), "open editor blocks installation")
        let afterDraft = try Data(contentsOf: model.vault.url)
        check(model.updateForms.contains(editor) && !model.updateFrozen && afterDraft == raw, "draft and budget preserved")
        updater.cancel(); model.updateForms.remove(editor)
        check(updater.state == .cancelled && updater.canTerminate(), "cancel waiting update has no installation on quit")
        updater.check()
        try await wait { if case .available = updater.state { return true }; return false }
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        let dialog = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80), styleMask: .titled, backing: .buffered, defer: false)
        parent.beginSheet(dialog, completionHandler: { _ in })
        BudgetWindows.register(parent)
        check(BudgetWindows.preferred(ordered: [settingsWindow, parent], key: dialog) === parent,
              "notification preserves the budget owning an active sheet")
        BudgetWindows.unregister(parent)
        updater.install()
        let afterDialog = try Data(contentsOf: model.vault.url)
        check({ if case .waiting = updater.state { return !model.updateFrozen && afterDialog == raw }; return false }(),
              "AppKit dialog blocks installation without changing the budget")
        parent.endSheet(dialog); dialog.orderOut(nil); parent.orderOut(nil)
        try await wait { model.updateBlocker == nil }
        updater.cancel()
        updater.check()
        try await wait { if case .available = updater.state { return true }; return false }
        updater.install()
        check(updater.state == .preparing && model.updateFrozen, "preparation freezes new writes")
        updater.dismiss()
        try await wait { !model.updateFrozen }
        let afterDismiss = try Data(contentsOf: model.vault.url)
        let pending = try UpdateSafetyStore(directory: model.root.appendingPathComponent("Updates.noindex")).pending()
        check(updater.state == .cancelled && !model.updateFrozen && pending.isEmpty && afterDismiss == raw && updater.canTerminate(),
              "closing preparation cancels installation and cleans only its snapshot")
        model.updateFrozen = true
        var refused = false
        do { try model.commit { $0.settings.baseCurrency = "USD" } } catch { refused = true }
        let afterFrozen = try Data(contentsOf: model.vault.url)
        check(refused && afterFrozen == raw, "frozen budget rejects a write atomically")
        model.updateFrozen = false
        model.updateVerificationPending = true
        refused = false
        do { try model.commit { $0.settings.baseCurrency = "USD" } } catch { refused = true }
        let afterUnverified = try Data(contentsOf: model.vault.url)
        check(refused && afterUnverified == raw, "unverified new launch rejects background and manual changes")
        model.updateVerificationPending = false
        model.loadPreview(.empty)
        try model.commit { db in
            db.settings.lastBackup = nil
            var account = Account(name: "Forecast regression fixture", currency: "RUB", openedOn: Day.today.adding(-1))
            account.financialKind = .deposit
            try Ledger.saveAccount(account, opening: 100_000, in: &db)
            var contract = FinancialContract(accountID: account.id, kind: .deposit, start: Day.today.adding(-1), end: Day.today.adding(2), annualPercent: "0")
            contract.frequency = .manual
            contract.manualRows = [ManualFinanceRow(date: .today, kind: .depositInterest, components: [FinancialAllocation(.interest, 100)], amount: 100)]
            try FinancialLedger.saveContract(contract, in: &db)
        }
        await model.waitForDailyBackup()
        check(!model.dailyBackupBusy && model.db?.settings.lastDaily == .today && model.backupError == nil,
              "background daily backup completes and records verified metadata")
        try await wait { !model.financialBusy }
        check(!model.financialBusy && model.financialEvents.values.flatMap({ $0 }).contains(where: { $0.amount == 100 }),
              "daily backup revision cannot leave financial forecasts busy")
        model.refreshFinancialForecasts()
        if var snapshot = model.db { snapshot.revision = (snapshot.revision ?? 0) + 1; model.db = snapshot }
        try await wait { !model.financialBusy }
        check(!model.financialBusy && !model.financialEvents.isEmpty,
              "stale financial snapshot retries against current revision")
        let scheduled = ScheduledPayment(title: "Fixture payment", comment: "Fictional contract only", amount: 100, currency: "RUB", dueOn: Day.today.adding(1))
        let secondScheduled = ScheduledPayment(title: "Second fixture payment", comment: "Another fictional contract", amount: 200, currency: "RUB", dueOn: Day.today.adding(2))
        try model.commit { db in
            try ScheduledPayments.save(scheduled, in: &db)
            try ScheduledPayments.save(secondScheduled, in: &db)
        }
        try await wait { !model.financialBusy }
        let token = FinancialReminderPlanner.databaseToken(model.db!.id)
        model.pendingFinancialRoute = (token, scheduled.eventID); model.handleFinancialNotification()
        check(model.sheet?.kind == .scheduledDetail && model.sheet?.entityID == scheduled.id, "scheduled reminder routes to its payment")
        model.pendingFinancialRoute = (token, secondScheduled.eventID); model.handleFinancialNotification()
        check(model.sheet?.kind == .scheduledDetail && model.sheet?.entityID == secondScheduled.id,
              "second reminder replaces an already open payment detail")
        model.pendingFinancialRoute = (token, scheduled.eventID); model.handleFinancialNotification()
        check(model.sheet?.entityID == scheduled.id, "consecutive reminders select their own payment")
        let draft = SheetRoute(kind: .scheduledPayment, entityID: secondScheduled.id)
        model.sheet = draft
        model.pendingFinancialRoute = (token, scheduled.eventID); model.handleFinancialNotification()
        check(model.sheet?.id == draft.id, "reminder preserves an unfinished payment editor")
        model.sheet = SheetRoute(kind: .scheduledDetail, entityID: scheduled.id)
        let otherWindowEditor = UUID(); model.updateForms.insert(otherWindowEditor)
        model.pendingFinancialRoute = (token, secondScheduled.eventID); model.handleFinancialNotification()
        check(model.sheet?.entityID == scheduled.id && model.updateForms.contains(otherWindowEditor),
              "reminder preserves editors in other windows")
        model.updateForms.remove(otherWindowEditor)
        if let event = model.financialEvents.values.flatMap({ $0 }).first(where: { $0.kind == .depositInterest }) {
            model.pendingFinancialRoute = (token, event.id); model.handleFinancialNotification()
            check(model.sheet == nil && model.historyAccount != nil,
                  "account reminder dismisses payment detail before showing account history")
        } else { check(false, "deposit reminder fixture exists") }
        model.sheet = nil; model.lock(); model.pendingFinancialRoute = (token, scheduled.eventID); model.handleFinancialNotification()
        check(model.db == nil && model.sheet == nil && model.pendingFinancialRoute != nil, "locked budget keeps payment route without exposing its contents")
        model.error = "Ошибка предыдущей попытки"
        model.unlock(password: "UI fixture password only")
        check(model.error == nil, "successful unlock clears the previous access error")
        try await wait { !model.financialBusy }
        check(model.sheet?.entityID == scheduled.id && model.pendingFinancialRoute == nil, "payment route opens after password unlock and forecast")
        model.sheet = nil; model.pendingFinancialRoute = ("other-budget", scheduled.eventID); model.handleFinancialNotification()
        check(model.sheet == nil, "notification from another budget cannot open a payment")
        try model.commit { db in var copy = scheduled; copy.cancelled = true; try ScheduledPayments.save(copy, in: &db) }
        try await wait { !model.financialBusy }
        model.pendingFinancialRoute = (token, scheduled.eventID); model.handleFinancialNotification()
        check(model.sheet == nil, "cancelled payment rejects stale notification route")
        for schema in [1, 2] {
            let migrated = AppModel()
            let bank = UserBank(name: "Fictional migration bank")
            try migrated.vault.transaction { $0.version = schema }
            let original = migrated.vault.db!
            let store = UpdateSafetyStore(directory: migrated.root.appendingPathComponent("Updates.noindex"))
            var record = try store.prepare(vault: migrated.vault, version: "1.3.1", build: 12, application: Bundle.main.bundleURL)
            record.phase = .handedOff; try store.write(record)
            migrated.lock()
            let launch = InstallUpdateManager(version: "1.3.1", build: 12)
            launch.attach(migrated)
            check(migrated.updateVerificationPending, "schema \(schema) waits for budget unlock before verification")
            migrated.unlock(password: "UI fixture password only")
            let afterMigration = try store.pending()
            check(!migrated.updateVerificationPending && launch.budgetVerificationError == nil && afterMigration.isEmpty,
                  "schema \(schema) migration completes first-launch verification")
            try migrated.commit { db in
                try FinancialLedger.saveBank(bank, in: &db)
                var account = db.accounts[0]; account.bankID = bank.id; try Ledger.saveAccount(account, in: &db)
            }
            check(migrated.db?.accounts[0].bankID == bank.id && migrated.db?.operations == original.operations,
                  "schema \(schema) bank change saves without altering existing operations")
            migrated.lock(); migrated.unlock(password: "UI fixture password only")
            check(!migrated.updateVerificationPending && migrated.db?.accounts[0].bankID == bank.id,
                  "schema \(schema) bank change survives a second unlock")
            migrated.lock(); try FileManager.default.removeItem(at: migrated.root)
        }
        let patched = AppModel()
        try patched.vault.transaction { $0.version = 1 }
        let oldSafety = UpdateSafetyStore(directory: patched.root.appendingPathComponent("Updates.noindex"))
        var oldRecord = try oldSafety.prepare(vault: patched.vault, version: "1.3.0", build: 11, application: Bundle.main.bundleURL)
        oldRecord.phase = .handedOff; try oldSafety.write(oldRecord)
        let oldSnapshot = try Data(contentsOf: oldSafety.snapshot(for: oldRecord))
        patched.lock()
        let patchUpdater = InstallUpdateManager(version: "1.3.1", build: 12)
        patchUpdater.attach(patched); patched.unlock(password: "UI fixture password only")
        check(!patched.updateVerificationPending && patchUpdater.budgetVerificationError == nil,
              "manual patch installation can reopen a budget blocked by the previous version")
        let patchBank = UserBank(name: "Fictional patch bank")
        try patched.commit { db in
            try FinancialLedger.saveBank(patchBank, in: &db)
            var account = db.accounts[0]; account.bankID = patchBank.id; try Ledger.saveAccount(account, in: &db)
        }
        check(patched.db?.accounts[0].bankID == patchBank.id, "manual patch installation restores bank editing")
        let retainedOldSnapshot = try Data(contentsOf: oldSafety.snapshot(for: oldRecord))
        let retainedOldRecords = try oldSafety.pending()
        check(retainedOldSnapshot == oldSnapshot && retainedOldRecords.contains(oldRecord),
              "manual patch preserves the prior version recovery snapshot")
        patched.lock(); try FileManager.default.removeItem(at: patched.root)
        let changed = AppModel()
        try changed.vault.transaction { $0.version = 1 }
        let changedSafety = UpdateSafetyStore(directory: changed.root.appendingPathComponent("Updates.noindex"))
        var changedRecord = try changedSafety.prepare(vault: changed.vault, version: "1.3.1", build: 12, application: Bundle.main.bundleURL)
        changedRecord.phase = .handedOff; try changedSafety.write(changedRecord)
        changed.lock(); try changed.vault.unlock(password: "UI fixture password only")
        try changed.vault.transaction { $0.accounts[0].name = "Actual later user change" }
        changed.db = changed.vault.db
        let changedGate = try ReleaseGate()
        let changedUpdater = InstallUpdateManager(client: AppUpdateClient(transport: Transport(gate: changedGate)), version: "1.3.1", build: 12)
        changedUpdater.attach(changed)
        check(changed.updateVerificationPending && changedUpdater.budgetVerificationError != nil,
              "real changes after migration keep the budget protected")
        changedUpdater.check()
        while !(await changedGate.waiting) { await Task.yield() }
        await changedGate.finishLate()
        try await wait { if case .available = changedUpdater.state { return true }; return false }
        check(changed.updateVerificationPending && changedUpdater.budgetVerificationError != nil && changedUpdater.canKeepCurrentBudget,
              "completed release check cannot hide a separate budget verification issue")
        let protectedBytes = try Data(contentsOf: changed.vault.url)
        refused = false
        do { try changed.commit { $0.accounts[0].bankID = nil } } catch { refused = true }
        let stillProtected = try Data(contentsOf: changed.vault.url)
        check(refused && protectedBytes == stillProtected && FileManager.default.fileExists(atPath: changedSafety.snapshot(for: changedRecord).path),
              "unresolved discrepancy preserves current ciphertext and original snapshot")
        changed.lock(); try FileManager.default.removeItem(at: changed.root)
        model.loadPreview(.empty)
        try model.commit { $0.settings.baseCurrency = "USD" }
        check(model.dailyBackupBusy && model.updateBlocker != nil,
              "updater waits for the pending daily backup")
        try model.commit { $0.settings.baseCurrency = "EUR" }
        await model.waitForDailyBackup()
        check(model.db?.settings.baseCurrency == "EUR" && model.db?.settings.lastDaily == .today && model.backupError == nil,
              "background backup metadata preserves a later ordinary write")
        model.loadPreview(.empty)
        let blockedBackup = model.backupFolder
        try Data("Fictional blocked path".utf8).write(to: blockedBackup)
        try model.commit { $0.settings.baseCurrency = "USD" }
        await model.waitForDailyBackup()
        check(model.db?.settings.baseCurrency == "USD" && model.db?.settings.lastDaily == nil && model.backupError != nil && !model.dailyBackupBusy,
              "failed background copy preserves the saved change and exposes a retryable warning")
        try FileManager.default.removeItem(at: blockedBackup)
        try model.commit { $0.settings.baseCurrency = "EUR" }
        await model.waitForDailyBackup()
        check(model.db?.settings.baseCurrency == "EUR" && model.db?.settings.lastDaily == .today && model.backupError == nil,
              "the next change retries a failed daily backup")
        model.loadPreview(.empty)
        try model.commit { $0.settings.baseCurrency = "USD" }
        let pendingBackup = Task { await model.waitForDailyBackup() }
        await Task.yield()
        model.lock()
        await pendingBackup.value
        check(model.db == nil && model.vault.db == nil && !model.dailyBackupBusy && model.backupError == nil,
              "lock cancels backup publication and cannot reopen the budget")
        model.vault.close()
        try FileManager.default.removeItem(at: model.root)
        print("Coordinator failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
