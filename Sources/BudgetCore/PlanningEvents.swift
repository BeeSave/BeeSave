import Foundation

public struct PlanningAttentionEvent: Equatable, Identifiable, Sendable {
    public var id: String; public var sourceID: UUID; public var type: String; public var title: String; public var date: Day
    public var reason: String; public var action: String; public var priority: Int; public var occurrence: PlannedOccurrence?
}
public enum PlanningEvents {
    public static func list(db: Database, today: Day = .today, financeEvents: [FinanceEvent]? = nil, projection: PlanningProjection? = nil) throws -> [PlanningAttentionEvent] {
        let settings = db.planningData.eventSettings; var rows: [PlanningAttentionEvent] = []
        let window = today.adding(max(settings.paymentDays,settings.deficitDays))
        for e in try PlanningEngine.events(db:db,from:today.adding(-365),through:window,financeEvents:financeEvents) where !e.income && e.purpose != .living {
            let type = e.source == "tax" ? "tax" : e.source == "project" ? "project" : "payment"
            guard e.date <= today.adding(settings.paymentDays) else { continue }
            let signature = "\(e.id).\(e.date).\(e.remaining.map(String.init) ?? "unknown")"
            rows.append(PlanningAttentionEvent(id:signature,sourceID:e.sourceID,type:type,title:e.title,date:e.date,reason:e.remaining == nil ? "Нужно уточнить сумму перед сроком" : e.date < today ? "Есть неоплаченный остаток после срока" : "Приближается срок обязательного платежа",action:e.remaining == nil ? "Уточнить сумму" : "Подтвердить оплату",priority:e.date < today ? 0 : 1,occurrence:e))
        }
        for c in db.financeData.contracts where c.kind == .deposit && c.status != .closed {
            guard let date = c.end, date >= today, date <= today.adding(settings.depositDays), let a = db.accounts.first(where: { $0.id == c.accountID }) else { continue }
            let id = "deposit.\(c.id).\(date)"
            rows.append(PlanningAttentionEvent(id:id,sourceID:c.id,type:"deposit",title:a.name,date:date,reason:"Заканчивается срок вклада. Проверьте условия продления или вывода.",action:"Решить о продлении",priority:2,occurrence:nil))
        }
        if let p = projection, let first = p.firstViolation, first <= today.adding(settings.deficitDays) {
            rows.append(PlanningAttentionEvent(id:"deficit.\(first).\(p.minimum).\(p.reserve)",sourceID:db.id,type:"deficit",title:"План требует внимания",date:first,reason:p.complete ? "Остаток опустится ниже выбранного резерва" : "Неполный прогноз показывает риск; уточните данные",action:"Сравнить варианты",priority:0,occurrence:nil))
        }
        for i in rows.indices { rows[i].priority = settings.priorityOverrides?[rows[i].type] ?? rows[i].priority }
        var keys = Set<String>()
        return rows.filter { e in
            settings.enabledTypes.contains(e.type) && !settings.hiddenKeys.contains(e.id) && !settings.sourceExclusions.contains(e.sourceID.uuidString) && (settings.snoozed[e.id] == nil || settings.snoozed[e.id]! <= today) && keys.insert(e.id).inserted
        }.sorted { $0.priority == $1.priority ? ($0.date == $1.date ? $0.id < $1.id : $0.date < $1.date) : $0.priority < $1.priority }
    }
}
