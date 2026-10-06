#if DEBUG && UI_SMOKE && NOTIFICATION_QA
import Foundation
import UserNotifications
import BudgetCore

extension AppModel {
    /// Available only in an isolated fixture app; the production budget is never opened.
    func prepareNotificationFixture(count: Int, scheduled: Bool = false) {
        notificationQAActive = true
        loadPreview(.empty)
        perform { db in
            for index in 0..<count {
                if scheduled {
                    var payment = ScheduledPayment(title: "Вымышленный договор \(index + 1)", comment: "Только тест системного напоминания", amount: 100_000, currency: "RUB", dueOn: .today)
                    payment.reminders = [ScheduledPaymentReminder(daysBefore: 0)]; payment.reminders[0].hour = 0
                    try ScheduledPayments.save(payment, in: &db); continue
                }
                var account = Account(name: "Вымышленный депозит \(index + 1)", currency: "RUB", openedOn: Day.today.adding(-1))
                account.financialKind = .deposit
                try Ledger.saveAccount(account, opening: 100_000, in: &db)
                var contract = FinancialContract(accountID: account.id, kind: .deposit, start: Day.today.adding(-1), end: Day.today.adding(2), annualPercent: "0")
                contract.frequency = .manual; contract.reminders.interestEnabled = true
                contract.reminders.paymentOffsets = [0]; contract.reminders.hour = 0; contract.reminders.minute = 0
                contract.manualRows = [ManualFinanceRow(date: .today, kind: .depositInterest, components: [FinancialAllocation(.interest, 100)], amount: 100)]
                try FinancialLedger.saveContract(contract, in: &db)
            }
            let events = try FinancialEngine.events(db: db)
            db.financeData.reminders.systemEnabled = true
            db.financeData.reminders.eventSnoozedUntil = Dictionary(uniqueKeysWithValues: events.enumerated().map { ($0.element.id, Date().addingTimeInterval(120 + Double($0.offset) * 60)) })
        }
    }
    func inspectNotificationFixture() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let settings = await center.notificationSettings()
        let requests = pending + delivered.map(\.request)
        let neutral = requests.allSatisfy { $0.content.title == "BeeSave" && $0.content.body == "Есть финансовое событие. Откройте приложение и разблокируйте бюджет." && Set($0.content.userInfo.keys.compactMap { $0 as? String }) == ["databaseToken", "eventToken"] }
        notice = "Тест macOS: разрешение \(settings.authorizationStatus.rawValue), в очереди \(pending.count), доставлено \(delivered.count), нейтральный текст \(neutral ? "да" : "нет")."
    }
}
#endif
