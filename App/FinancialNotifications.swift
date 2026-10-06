import Foundation
import UserNotifications
import BudgetCore

struct FinancialNotificationStatus {
    var message: String
    var scheduledThrough: Date?
    var pendingCount = 0
    var error: String?
}

@MainActor enum FinancialNotifications {
    private static var generation = UUID()
    static func enable(model: AppModel) async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard granted else { model.notice = "Системные уведомления выключены. Все события доступны в финансовом календаре."; return }
            try model.commit { db in var book = db.financeData; book.reminders.systemEnabled = true; db.finances = book }
        } catch { model.error = error.localizedDescription }
    }
    static func synchronize(db: Database, events: [FinanceEvent]) async -> FinancialNotificationStatus? {
        #if DEBUG && UI_SMOKE && !NOTIFICATION_QA
        return FinancialNotificationStatus(message: "Тестовая сборка: системные уведомления не отправляются.")
        #else
        let current = UUID(); generation = current
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let prior = Set(delivered.map { $0.request.identifier })
        let settings = await center.notificationSettings()
        guard generation == current else { return nil }
        let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        do {
            let now = Date()
            let all = allowed ? try FinancialReminderPlanner.plan(db: db, events: events, now: now, limit: Int.max, delivered: prior) : []
            let plan = Array(all.prefix(60))
            let wanted = Set(plan.map(\.id)), stale = pending.filter { $0.identifier.hasPrefix(FinancialReminderPlanner.prefix) && !wanted.contains($0.identifier) }.map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: stale)
            let validEvents = Set(events.filter { !$0.isFulfilled }.map(\.id))
            let obsolete = delivered.filter { $0.request.identifier.hasPrefix(FinancialReminderPlanner.prefix) && ($0.request.content.userInfo["databaseToken"] as? String != FinancialReminderPlanner.databaseToken(db.id) || !validEvents.contains($0.request.content.userInfo["eventToken"] as? String ?? "")) }.map { $0.request.identifier }
            center.removeDeliveredNotifications(withIdentifiers: obsolete)
            let existing = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
            for request in plan {
                if let trigger = existing[request.id]?.trigger as? UNCalendarNotificationTrigger, let date = trigger.nextTriggerDate(), abs(date.timeIntervalSince(request.fireAt)) < 1 { continue }
                guard generation == current else { return nil }
                let content = UNMutableNotificationContent(); content.title = "BeeSave"; content.body = "Есть финансовое событие. Откройте приложение и разблокируйте бюджет."; content.sound = .default
                content.userInfo = ["databaseToken": request.databaseToken, "eventToken": request.eventToken]
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: request.fireAt); components.timeZone = calendar.timeZone
                try await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
                if generation != current { center.removePendingNotificationRequests(withIdentifiers: [request.id]); return nil }
            }
            guard generation == current else { return nil }
            if !db.financeData.reminders.systemEnabled { return FinancialNotificationStatus(message: "Системные уведомления выключены.") }
            if !allowed { return FinancialNotificationStatus(message: "Разрешение macOS не предоставлено. Разрешите уведомления BeeSave в системных настройках.") }
            let confirmed = await center.pendingNotificationRequests()
            guard generation == current else { return nil }
            let confirmedIDs = Set(confirmed.map(\.identifier))
            guard wanted.isSubset(of: confirmedIDs) else { throw BudgetError.storage("macOS не подтвердила часть расписания. Откройте финансовый календарь и повторите пересчёт.") }
            let through = all.count > 60 ? all[60].fireAt.addingTimeInterval(-1) : now.addingTimeInterval(45 * 86400)
            return FinancialNotificationStatus(message: all.count > 60 ? "Очередь заполнена. Следующие события доступны в календаре; откройте бюджет до конца покрытия." : "Расписание проверено в macOS. Открывайте бюджет для продления покрытия.", scheduledThrough: through, pendingCount: wanted.count)
        } catch {
            guard generation == current else { return nil }
            return FinancialNotificationStatus(message: "Расписание системных уведомлений не подтверждено. Финансовый календарь доступен.", error: error.localizedDescription)
        }
        #endif
    }
}
