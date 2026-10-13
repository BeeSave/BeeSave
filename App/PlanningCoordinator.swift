import SwiftUI
import BudgetCore

extension AppModel {
    func savePlanning(_ command: PlanningCommand, reason: String = "Изменение пользователем", expectedRevision: UInt64? = nil) throws {
        guard let db else { throw BudgetError.locked }
        if let expectedRevision,expectedRevision != (db.revision ?? 0) { throw BudgetError.conflict("План изменился после открытия формы. Откройте её заново и проверьте актуальные данные.") }
        let proposal = PlanningProposal(revision:db.revision ?? 0,command:command,explanation:reason)
        let access = PlanningAccess(actorID:db.id,fullPlan:true,canApply:true,sessionID:planningSession.id), requestID = UUID()
        try commit { _ = try PlanningActions.apply(proposal,requestID:requestID,access:access,session:planningSession,in:&$0) }
    }
    func changePlanning(_ command: PlanningCommand, reason: String = "Изменение пользователем") {
        do { try savePlanning(command,reason:reason) } catch { self.error = error.localizedDescription }
    }
    func cancelPlanning() {
        planningTask?.cancel(); planningTask = nil; planningRequest = UUID(); planningBusy = false
        planningProjection = nil; planningAttention = []; planningRows = []; planningError = nil
    }
    func refreshPlanning() {
        planningTask?.cancel(); guard let snapshot = db else { cancelPlanning(); return }
        let id = UUID(); planningRequest = id; planningBusy = true; planningError = nil
        let financial = Array(financialEvents.values.joined()), errors = Array(financialErrors.values)
        planningTask = Task {
            let worker = Task.detached(priority:.userInitiated) { () throws -> (PlanningProjection,[PlannedOccurrence],[PlanningAttentionEvent]) in
                let end = try FinanceMath.addingMonths(Day.today,12)
                var projection = try PlanningEngine.projection(db:snapshot,through:end,financeEvents:financial)
                projection.missing += errors
                let rows = try PlanningEngine.events(db:snapshot,from:.today.adding(-365),through:end,financeEvents:financial)
                let attention = try PlanningEvents.list(db:snapshot,financeEvents:financial,projection:projection)
                return (projection,rows,attention)
            }
            do {
                let result = try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
                guard !Task.isCancelled, planningRequest == id, db?.id == snapshot.id, db?.revision == snapshot.revision else { return }
                planningProjection = result.0; planningRows = result.1; planningAttention = result.2; planningBusy = false; planningTask = nil
            } catch is CancellationError {} catch { guard planningRequest == id,db != nil else { return }; planningError = error.localizedDescription; planningBusy = false; planningTask = nil }
        }
    }
    func openPlanningSource(_ row: PlannedOccurrence) {
        switch row.source {
        case "scheduled": sheet = SheetRoute(kind:.scheduledDetail,entityID:row.sourceID)
        case "finance": if let contract = db?.financeData.contracts.first(where:{ $0.id == row.sourceID }) { openHistory(contract.accountID) }
        case "project", "projectLoan": planningProjectID = row.projectID; section = .projects
        case "tax": sheet = SheetRoute(kind:.taxProfile,entityID:row.sourceID)
        default: sheet = SheetRoute(kind:.planFlow,entityID:row.sourceID)
        }
    }
}
