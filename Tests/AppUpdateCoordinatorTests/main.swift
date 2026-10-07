import AppKit
import BudgetCore

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
        _ = NSApplication.shared
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            if !condition { failures += 1; print("FAIL: " + name) } else { print("PASS: " + name) }
        }
        func wait(_ condition: @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let budgetWindow = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        let otherBudgetWindow = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        let settingsWindow = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        BudgetWindows.register(budgetWindow); BudgetWindows.register(otherBudgetWindow)
        check(BudgetWindows.preferred(ordered: [settingsWindow, budgetWindow, otherBudgetWindow], key: settingsWindow) === budgetWindow,
              "notification selects the budget window over foreground settings")
        check(BudgetWindows.preferred(ordered: [budgetWindow, otherBudgetWindow], key: otherBudgetWindow) === otherBudgetWindow,
              "notification preserves the active budget window")
        BudgetWindows.unregister(budgetWindow); BudgetWindows.unregister(otherBudgetWindow)
        check(BudgetWindows.preferred(ordered: [settingsWindow, budgetWindow], key: settingsWindow) == nil,
              "notification does not select unrelated or detached windows")
        let model = AppModel()
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
        try await wait { !model.financialBusy }
        check(!model.financialBusy && model.financialEvents.values.flatMap({ $0 }).contains(where: { $0.amount == 100 }),
              "daily backup revision cannot leave financial forecasts busy")
        model.refreshFinancialForecasts()
        if var snapshot = model.db { snapshot.revision = (snapshot.revision ?? 0) + 1; model.db = snapshot }
        try await wait { !model.financialBusy }
        check(!model.financialBusy && !model.financialEvents.isEmpty,
              "stale financial snapshot retries against current revision")
        let scheduled = ScheduledPayment(title: "Fixture payment", comment: "Fictional contract only", amount: 100, currency: "RUB", dueOn: Day.today.adding(1))
        try model.commit { try ScheduledPayments.save(scheduled, in: &$0) }
        try await wait { !model.financialBusy }
        let token = FinancialReminderPlanner.databaseToken(model.db!.id)
        model.pendingFinancialRoute = (token, scheduled.eventID); model.handleFinancialNotification()
        check(model.sheet?.kind == .scheduledDetail && model.sheet?.entityID == scheduled.id, "scheduled reminder routes to its payment")
        model.sheet = nil; model.lock(); model.pendingFinancialRoute = (token, scheduled.eventID); model.handleFinancialNotification()
        check(model.db == nil && model.sheet == nil && model.pendingFinancialRoute != nil, "locked budget keeps payment route without exposing its contents")
        model.unlock(password: "UI fixture password only")
        try await wait { !model.financialBusy }
        check(model.sheet?.entityID == scheduled.id && model.pendingFinancialRoute == nil, "payment route opens after password unlock and forecast")
        model.sheet = nil; model.pendingFinancialRoute = ("other-budget", scheduled.eventID); model.handleFinancialNotification()
        check(model.sheet == nil, "notification from another budget cannot open a payment")
        try model.commit { db in var copy = scheduled; copy.cancelled = true; try ScheduledPayments.save(copy, in: &db) }
        try await wait { !model.financialBusy }
        model.pendingFinancialRoute = (token, scheduled.eventID); model.handleFinancialNotification()
        check(model.sheet == nil, "cancelled payment rejects stale notification route")
        model.vault.close()
        try FileManager.default.removeItem(at: model.root)
        print("Coordinator failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
