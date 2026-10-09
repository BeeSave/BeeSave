import AppKit
import UserNotifications

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var updater: InstallUpdateManager?
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard updater?.canTerminate() != false else { return .terminateCancel }
        guard let model, model.dailyBackupBusy else { return .terminateNow }
        Task { @MainActor in
            await model.waitForDailyBackup()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        BudgetWindows.reopen?(); BudgetWindows.bringForward(); return false
    }
    func applicationWillTerminate(_ notification: Notification) { model?.vault.close() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        // Use the bundled icon directly so Dock does not retain a cached placeholder.
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url), icon.isValid else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}

extension ApplicationDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let token = response.notification.request.content.userInfo["databaseToken"] as? String
        let event = response.notification.request.content.userInfo["eventToken"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            BudgetWindows.reopen?()
            BudgetWindows.bringForward()
            if let token, let event { model?.pendingFinancialRoute = (token, event); model?.handleFinancialNotification() }
            completionHandler()
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
}
