import Foundation
import BudgetCore

extension AppModel {
    func handleFinancialNotification() {
        guard let route = pendingFinancialRoute, let db, !financialBusy, !updateFrozen else { return }
        pendingFinancialRoute = nil
        guard route.0 == FinancialReminderPlanner.databaseToken(db.id), let event = financialEvents.values.flatMap({ $0 }).first(where: { $0.id == route.1 }), !event.isFulfilled else { notice = "Напоминание больше не актуально. Проверьте финансовый календарь."; return }
        guard sheet == nil && updateForms.isEmpty else { notice = "Финансовое событие доступно в календаре после завершения открытой формы."; return }
        if event.kind == .scheduledPayment {
            guard db.financeData.scheduledPayments?.contains(where: { $0.id == event.contractID && !$0.cancelled }) == true else { return }
            section = .expenses; showScheduledExpenses = true; sheet = SheetRoute(kind: .scheduledDetail, entityID: event.contractID); return
        }
        guard let contract = db.financeData.contracts.first(where: { $0.id == event.contractID }) else { return }
        openHistory(contract.accountID)
    }
    func cancelFinancialForecasts() { financialTask?.cancel(); financialTask = nil; financialCalculationID = UUID(); financialBusy = false }
    func refreshFinancialForecasts() {
        cancelFinancialForecasts()
        guard let snapshot = db else { return }
        let calculation = UUID(); financialCalculationID = calculation; financialBusy = true
        financialTask = Task {
            let worker = Task.detached(priority: .userInitiated) { () -> ([UUID: [FinanceEvent]], [UUID: String], [UUID: DebtSummary]) in
                var events: [UUID: [FinanceEvent]] = [:], errors: [UUID: String] = [:], debts: [UUID: DebtSummary] = [:]
                let operations = FinancialLedger.operationsByAccount(in: snapshot)
                for contract in snapshot.financeData.contracts {
                    if Task.isCancelled { break }
                    do { var projection = snapshot; projection.operations = operations[contract.accountID] ?? []; events[contract.id] = try FinancialEngine.events(contract: contract, db: projection); if contract.kind.isDebt { debts[contract.accountID] = try FinancialLedger.debt(accountID: contract.accountID, db: projection) } }
                    catch is CancellationError { break }
                    catch { errors[contract.id] = error.localizedDescription }
                }
                do { for event in try ScheduledPayments.events(db: snapshot) { events[event.contractID] = [event] } }
                catch { errors[snapshot.id] = error.localizedDescription }
                return (events, errors, debts)
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, financialCalculationID == calculation else { return }
            guard db?.id == snapshot.id, db?.revision == snapshot.revision else { refreshFinancialForecasts(); return }
            financialEvents = result.0; financialErrors = result.1; financialDebts = result.2; financialBusy = false; handleFinancialNotification()
            #if DEBUG && UI_SMOKE && NOTIFICATION_QA
            // Inspect delivery from a closed fixture app before replacing its database / queue.
            guard notificationQAActive else { return }
            #endif
            let status = await FinancialNotifications.synchronize(db: snapshot, events: result.0.values.flatMap { $0 })
            guard !Task.isCancelled, financialCalculationID == calculation, db?.id == snapshot.id, db?.revision == snapshot.revision else { return }
            financialNotificationStatus = status
        }
    }
}
