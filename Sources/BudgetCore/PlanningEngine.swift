import Foundation

public struct PlannedOccurrence: Equatable, Identifiable, Sendable {
    public var cashImpact: Bool?; public var incomplete: Bool?
    public var id: String; public var sourceID: UUID; public var title: String; public var date: Day; public var anchor: Day
    public var amount: Int64?; public var remaining: Int64?; public var currency: String; public var income: Bool
    public var reportAmount: Int64?; public var certainty: PlanCertainty; public var purpose: PlanPurpose
    public var accountID: UUID?; public var projectID: UUID?; public var source: String; public var notes: [String]
}
public struct LiquidityPoint: Equatable, Identifiable, Sendable {
    public var id: String { event.id }; public var event: PlannedOccurrence; public var balance: Int64; public var belowReserve: Bool
}
public struct PlanningProjection: Equatable, Sendable {
    public var calculationID: String; public var snapshotRevision: UInt64; public var currency: String; public var opening: Int64
    public var ending: Int64; public var minimum: Int64; public var firstViolation: Day?; public var reserve: Int64
    public var earmarkedEnding: Int64 = 0
    public var freeEnding: Int64 { get throws { try Money.add(Money.add(ending,-reserve),-earmarkedEnding) } }
    public var points: [LiquidityPoint]; public var missing: [String]; public var assumptions: [String]
    public var complete: Bool { missing.isEmpty }
}
public struct SavingsProjection: Equatable, Sendable {
    public var requiredMonthly: Int64; public var achievableOn: Day?; public var remaining: Int64
}
public enum PlanningEngine {
    public static func key(_ flow: PlanFlow, anchor: Day) -> String { flow.id.uuidString.lowercased() + "." + anchor.rawValue }
    public static func occurrences(flow: PlanFlow, db: Database, from: Day, through: Day, paidByOccurrence: [String:Int64]? = nil) throws -> [PlannedOccurrence] {
        guard from <= through else { return [] }
        if let history = flow.history,!history.isEmpty {
            var rows: [PlannedOccurrence] = [], lower: Day?
            for version in history.sorted(by:{ $0.validUntil < $1.validUntil }) {
                var old = try JSONDecoder().decode(PlanFlow.self,from:version.snapshot); old.history = nil; old.exceptions = flow.exceptions
                guard old.id == flow.id else { throw BudgetError.corrupt }
                rows += try occurrences(flow:old,db:db,from:from,through:through,paidByOccurrence:paidByOccurrence).filter { $0.anchor <= version.validUntil && (lower == nil || $0.anchor >= lower!) }
                lower = version.validUntil.adding(1)
            }
            var current = flow; current.history = nil
            rows += try occurrences(flow:current,db:db,from:from,through:through,paidByOccurrence:paidByOccurrence).filter { lower == nil || $0.anchor >= lower! }
            return rows.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        }
        guard flow.enabled else { return [] }
        let last = min(through,flow.end ?? through); if last < flow.start { return [] }
        var anchors: [Day] = []
        switch flow.frequency {
        case .once: anchors = [flow.start]
        case .manual: anchors = flow.dates.sorted()
        case .weekly:
            let first = max(0,FinanceMath.days(flow.start,from) / 7 - 1)
            for index in first..<(first + 10000) { try Task.checkCancellation(); if index * 7 > FinanceMath.days(flow.start,last) { break }; let date = flow.start.adding(index * 7); if date > last { break }; anchors.append(date) }
        case .monthly, .yearly:
            let months = max(0,(Int(from.rawValue.prefix(4))! - Int(flow.start.rawValue.prefix(4))!) * 12 + Int(from.rawValue.dropFirst(5).prefix(2))! - Int(flow.start.rawValue.dropFirst(5).prefix(2))!)
            let step = flow.frequency == .yearly ? 12 : 1, first = max(0,months / step - 1)
            for index in first..<(first + 6000) { try Task.checkCancellation(); let date = try FinanceMath.addingMonths(flow.start,index * step); if date > last { break }; anchors.append(date) }
        }
        // A moved occurrence outside the regular query window still belongs to its original anchor.
        anchors += flow.exceptions.filter { $0.date.map { $0 >= from && $0 <= through } == true }.map(\.anchor)
        var rows: [PlannedOccurrence] = []
        let paidIndex = try paidByOccurrence ?? executionIndex(db:db)
        for anchor in Set(anchors).sorted() where anchor >= flow.start && anchor <= (flow.end ?? last) {
            let exception = flow.exceptions.first { $0.anchor == anchor }; if exception?.cancelled == true { continue }
            let date = exception?.date ?? anchor; guard date >= from, date <= through else { continue }
            let id = key(flow,anchor:anchor), amount = exception?.amount ?? flow.amount
            let paid = paidIndex[id] ?? 0
            let remaining = exception?.closed == true ? 0 : amount.map { max(0,$0 - paid) }
            rows.append(PlannedOccurrence(id:id,sourceID:flow.id,title:flow.title,date:date,anchor:anchor,amount:amount,remaining:remaining,currency:flow.currency,income:flow.purpose == .income,reportAmount:remaining,certainty:flow.certainty,purpose:flow.purpose,accountID:flow.accountID,projectID:flow.projectID,source:"plan",notes:flow.comment.isEmpty ? [] : [flow.comment]))
        }
        return rows
    }
    public static func validAnchor(flow: PlanFlow, occurrenceID: String) throws -> Bool {
        let prefix = flow.id.uuidString.lowercased() + "."; guard occurrenceID.hasPrefix(prefix),let day = try? Day(String(occurrenceID.dropFirst(prefix.count))) else { return false }
        var state = flow
        for version in (flow.history ?? []).sorted(by:{ $0.validUntil < $1.validUntil }) where day <= version.validUntil { state = try JSONDecoder().decode(PlanFlow.self,from:version.snapshot); break }
        guard day >= state.start,state.end == nil || day <= state.end! else { return false }
        switch state.frequency {
        case .once: return day == state.start
        case .manual: return state.dates.contains(day)
        case .weekly: return FinanceMath.days(state.start,day) % 7 == 0
        case .monthly,.yearly:
            let months = (Int(day.rawValue.prefix(4))! - Int(state.start.rawValue.prefix(4))!) * 12 + Int(day.rawValue.dropFirst(5).prefix(2))! - Int(state.start.rawValue.dropFirst(5).prefix(2))!
            let anchored = try FinanceMath.addingMonths(state.start,months); return months >= 0 && (state.frequency != .yearly || months % 12 == 0) && anchored == day
        }
    }
    private static func executionIndex(db: Database) throws -> [String:Int64] {
        guard !db.planningData.allocations.isEmpty else { return [:] }
        let ids = Set(db.operations.map(\.id)); var result: [String:Int64] = [:]
        for allocation in db.planningData.allocations where ids.contains(allocation.operationID) { result[allocation.occurrenceID] = try Money.add(result[allocation.occurrenceID] ?? 0,allocation.amount) }
        return result
    }
    public static func events(db: Database, from: Day, through: Day, financeEvents: [FinanceEvent]? = nil, includeConditional: Bool = false) throws -> [PlannedOccurrence] {
        var rows: [PlannedOccurrence] = []; let execution = try executionIndex(db:db)
        for flow in db.planningData.flows where flow.scheduledPaymentID == nil && flow.financeEventID == nil {
            let queryFrom = flow.purpose == .living ? from.firstOfMonth : flow.purpose == .payment ? min(from,flow.start) : from
            let occurrences = try occurrences(flow:flow,db:db,from:queryFrom,through:through,paidByOccurrence:execution).filter { includeConditional || $0.certainty != .conditional }
            rows += occurrences.compactMap { row in
                var row = row
                if flow.purpose == .living && row.date < from { guard row.anchor.month == from.month else { return nil }; row.date = from; row.notes.append("Оставшийся лимит текущего периода; консервативно в начале прогноза") }
                return row
            }
        }
        for i in rows.indices {
            guard let parent = db.planningData.flows.first(where:{ $0.id == rows[i].sourceID }),parent.purpose == .living else { continue }
            let childIDs = Set(db.planningData.flows.filter { $0.parentFlowID == parent.id }.map(\.id))
            let children = rows.filter { childIDs.contains($0.sourceID) && $0.anchor.month == rows[i].anchor.month }
            guard !children.isEmpty else { continue }
            if children.contains(where:{ $0.amount == nil }) { rows[i].remaining = nil; rows[i].reportAmount = nil; continue }
            let reserved = try children.reduce(Int64(0)) { try Money.add($0,max($1.amount!,execution[$1.id] ?? 0)) }
            rows[i].remaining = rows[i].remaining.map { max(0,$0-reserved) }; rows[i].reportAmount = rows[i].remaining
            rows[i].title += " · нераспределённая часть"
        }
        for p in db.financeData.scheduledPayments ?? [] where !p.cancelled {
            let remaining = try ScheduledPayments.remaining(p,db:db)
            guard remaining > 0, p.dueOn <= through, (p.dueOn >= from || p.dueOn < .today) else { continue }
            rows.append(PlannedOccurrence(id:p.eventID,sourceID:p.id,title:p.title,date:p.dueOn,anchor:p.dueOn,amount:p.amount,remaining:remaining,currency:p.currency,income:false,reportAmount:remaining,certainty:.committed,purpose:.payment,accountID:p.accountID,projectID:p.projectID,source:"scheduled",notes:[p.comment]))
        }
        let financial = try financeEvents ?? FinancialEngine.events(db:db)
        var paidExpenseIndex: [String:Int64] = [:]
        if !db.financeData.fulfillments.isEmpty {
            let operations = Dictionary(uniqueKeysWithValues:db.operations.map { ($0.id,$0) }); var seen: [String:Set<UUID>] = [:]
            for fulfillment in db.financeData.fulfillments { for id in fulfillment.operationIDs where seen[fulfillment.eventID]?.contains(id) != true {
                seen[fulfillment.eventID,default:[]].insert(id)
                if let o = operations[id],o.kind == .expense,[.interest,.fee,.penalty,.tax].contains(o.financial?.component ?? .principal) { paidExpenseIndex[fulfillment.eventID] = try Money.add(paidExpenseIndex[fulfillment.eventID] ?? 0,o.amount) }
            } }
        }
        for e in financial where !e.isFulfilled && (e.date >= from || (!([FinanceEventKind.depositInterest,.depositMaturity].contains(e.kind)) && e.date < .today)) && e.date <= through && e.kind != .scheduledPayment {
            guard let c = db.financeData.contracts.first(where: { $0.id == e.contractID }), let a = db.accounts.first(where: { $0.id == c.accountID }) else { continue }
            if [.renewalDecision,.rateChange,.other].contains(e.kind) { continue }
            let income = e.kind == .depositInterest || e.kind == .depositMaturity
            let expenseComponents = try e.components.filter { [.interest,.fee,.penalty,.tax].contains($0.component) }.reduce(Int64(0)) { try Money.add($0,$1.amount) }
            let remaining = e.remaining ?? e.amount
            let paidExpenses = paidExpenseIndex[e.id] ?? 0
            let expenseRemaining = max(0,expenseComponents - paidExpenses)
            let report = e.kind == .depositInterest ? remaining : e.kind == .depositMaturity ? e.amount(.interest) : remaining.map { min($0,expenseRemaining) }
            var row = PlannedOccurrence(id:e.id,sourceID:c.id,title:a.name + " · " + e.kind.title,date:e.date,anchor:e.date,amount:e.amount,remaining:remaining,currency:a.currency,income:income,reportAmount:report,certainty:.committed,purpose:income ? .income : .payment,accountID:a.id,projectID:db.projects.first { $0.details?.loan?.contractID == c.id }?.id,source:"finance",notes:e.notes)
            row.incomplete = e.accuracy == .incomplete
            if e.kind == .depositInterest {
                let terms = c.terms(on:e.date)
                let destination = terms?.deposit.payoutAccountID.flatMap { id in db.accounts.first { $0.id == id } }
                row.cashImpact = terms?.deposit.capitalize != true && destination?.kind == .ordinary && destination?.businessProjectID == nil
            }
            rows.append(row)
        }
        let accountedFlows = Set(db.planningData.flows.map(\.id))
        for p in db.projects { guard let d = p.details else { continue }
            for c in d.costs where (c.contracted || d.stage == .active || (includeConditional && d.stage != .cancelled && d.stage != .completed)) && c.scheduledPaymentID == nil && (c.flowID == nil || !accountedFlows.contains(c.flowID!)) && (c.dueOn >= from || c.dueOn < .today) && c.dueOn <= through {
                if let party = c.participantID, d.participants.first(where: { $0.id == party })?.isUser != true { continue }
                let paid = try ProjectEngine.paid(cost:c,details:d,db:db), remaining = max(0,c.amount - paid)
                rows.append(PlannedOccurrence(id:"project.\(p.id).\(c.id)",sourceID:c.id,title:p.name + " · " + c.title,date:c.dueOn,anchor:c.dueOn,amount:c.amount,remaining:remaining,currency:d.currency,income:false,reportAmount:remaining,certainty:c.contracted ? .committed : .estimated,purpose:.payment,accountID:nil,projectID:p.id,source:"project",notes:[]))
            }
            if let loan = d.loan, (includeConditional || d.stage == .active), loan.contractID == nil, loan.principal > 0 {
                for r in try ProjectEngine.loanSchedule(loan) where r.date >= from && r.date <= through {
                    rows.append(PlannedOccurrence(id:"loan.\(p.id).\(r.id)",sourceID:p.id,title:p.name + " · платёж",date:r.date,anchor:r.date,amount:try r.payment,remaining:try r.payment,currency:d.currency,income:false,reportAmount:r.interest,certainty:d.stage == .active ? .estimated : .conditional,purpose:.payment,accountID:nil,projectID:p.id,source:"projectLoan",notes:[loan.note]))
                }
            }
        }
        for p in db.planningData.taxes where p.refundOperationID == nil {
            let r = try CountryModules.calculate(p,revision:db.revision ?? 0)
            guard let date = p.expectedOn, (date >= from || date < .today), date <= through else { continue }
            if !r.complete {
                rows.append(PlannedOccurrence(id:"tax.\(p.id)",sourceID:p.id,title:p.title + " · уточните налог",date:date,anchor:date,amount:nil,remaining:nil,currency:"RUB",income:false,reportAmount:nil,certainty:.estimated,purpose:.payment,accountID:nil,projectID:nil,source:"tax",notes:r.missing)); continue
            }
            let income = (r.refund ?? 0) > 0, amount = income ? r.refund! : r.payable ?? 0
            guard amount > 0, !income || includeConditional else { continue }
            rows.append(PlannedOccurrence(id:"tax.\(p.id)",sourceID:p.id,title:p.title + (income ? " · возврат (оценка)" : " · к уплате"),date:date,anchor:date,amount:amount,remaining:amount,currency:"RUB",income:income,reportAmount:amount,certainty:income ? .conditional : .estimated,purpose:income ? .income : .payment,accountID:nil,projectID:nil,source:"tax",notes:r.assumptions))
        }
        return rows.filter { ($0.remaining ?? 1) > 0 && (includeConditional || $0.certainty != .conditional) }.sorted { $0.date == $1.date ? ($0.income == $1.income ? $0.id < $1.id : !$0.income) : $0.date < $1.date }
    }
    public static func affectsPersonal(_ event: PlannedOccurrence, db: Database) -> Bool {
        if event.cashImpact == false { return false }
        if let flow = db.planningData.flows.first(where:{ $0.id == event.sourceID }),flow.personalImpact == false { return false }
        if let id = event.accountID,db.accounts.first(where:{ $0.id == id })?.businessProjectID != nil { return false }
        if let tax = db.planningData.taxes.first(where:{ $0.id == event.sourceID }),let owner = tax.ownerID,owner != db.id { return false }
        if event.source == "scheduled" {
            for project in db.projects { if let d = project.details,let cost = d.costs.first(where:{ $0.scheduledPaymentID == event.sourceID }),let id = cost.participantID,d.participants.first(where:{ $0.id == id })?.isUser != true { return false } }
        }
        return true
    }
    public static func converted(_ amount: Int64, currency: String, to: String, db: Database, date: Day) throws -> Int64 {
        if amount == 0 || currency == to { return amount }
        let rates = db.planningData.forecastRates
        guard let rate = try Reports.rate(from:currency,to:to,rates:rates,on:date) else { throw BudgetError.missing("Нет прогнозного курса") }
        return try Money.convert(amount,from:currency,to:to,rate:rate)
    }
    public static func projection(db: Database, from: Day = .today, through: Day, currency: String? = nil, financeEvents: [FinanceEvent]? = nil, includeConditional: Bool = false, opening: Int64? = nil) throws -> PlanningProjection {
        try Task.checkCancellation()
        let currency = currency ?? db.settings.baseCurrency; var missing: [String] = []
        var balance = opening ?? 0
        if opening == nil {
            for a in db.accounts where a.kind == .ordinary && a.businessProjectID == nil {
                do { balance = try Money.add(balance,converted(db.balance(a.id,on:from),currency:a.currency,to:currency,db:db,date:from)) }
                catch { missing.append("Остаток \(a.name): нужен прогнозный курс \(a.currency)/\(currency)") }
            }
        }
        for profile in db.planningData.taxes where profile.ownerID == nil || profile.ownerID == db.id {
            let tax = try CountryModules.calculate(profile,revision:db.revision ?? 0)
            if !tax.complete { missing.append(profile.title + ": " + tax.missing.joined(separator:"; ")) }
            else if (tax.payable ?? 0) > 0 && profile.expectedOn == nil { missing.append(profile.title + ": задайте дату уплаты") }
        }
        let initial = balance; var minimum = balance, points: [LiquidityPoint] = [], first: Day?
        let reserve: Int64
        do { reserve = try converted(db.planningData.reserve,currency:db.planningData.reserveCurrency,to:currency,db:db,date:from) }
        catch { reserve = 0; missing.append("Не оценён резерв") }
        if balance < reserve { first = from }
        for e in try events(db:db,from:from,through:through,financeEvents:financeEvents,includeConditional:includeConditional) {
            if !affectsPersonal(e,db:db) { continue }
            try Task.checkCancellation()
            if e.incomplete == true { missing.append(e.title + ": условия договорного прогноза неполны") }
            guard let amount = e.remaining else { missing.append(e.title + ": уточните сумму"); continue }
            do {
                let converted = try self.converted(amount,currency:e.currency,to:currency,db:db,date:e.date)
                balance = try Money.add(balance,e.income ? converted : -converted)
                minimum = min(minimum,balance); if first == nil && balance < reserve { first = max(from,e.date) }
                points.append(LiquidityPoint(event:e,balance:balance,belowReserve:balance < reserve))
            } catch BudgetError.overflow { throw BudgetError.overflow }
            catch { missing.append(e.title + ": нужен прогнозный курс") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; let data = try encoder.encode(db.planningData)
        var result = PlanningProjection(calculationID:VaultCrypto.fingerprint(data) + ".\(db.revision ?? 0).\(from).\(through).\(currency).\(initial).\(includeConditional)",snapshotRevision:db.revision ?? 0,currency:currency,opening:initial,ending:balance,minimum:minimum,firstViolation:first,reserve:reserve,points:points,missing:Array(Set(missing)).sorted(),assumptions:["Только собственные денежные счета; вклады доступны по событиям", "Неизвестный порядок дня: сначала выплаты", "Условные поступления \(includeConditional ? "включены" : "исключены")", "Выделение на цель не является расходом"])
        var earmarked: Int64 = 0
        for goal in db.planningData.goals {
            let months = max(0,(Int(through.rawValue.prefix(4))! - Int(from.rawValue.prefix(4))!) * 12 + Int(through.rawValue.dropFirst(5).prefix(2))! - Int(from.rawValue.dropFirst(5).prefix(2))! + (through >= from.lastOfMonth ? 1 : 0))
            let eligibleMonths = goal.dueOn < from ? 0 : months
            let planned = min(Decimal(max(0,goal.target-goal.allocated)),try Money.multiply(Decimal(goal.monthly),Decimal(eligibleMonths)))
            let total = try Money.add(goal.allocated,Money.integer(planned))
            if let id = goal.accountID,db.accounts.first(where:{ $0.id == id })?.kind == .deposit { continue }
            do { earmarked = try Money.add(earmarked,converted(total,currency:goal.currency,to:currency,db:db,date:through)) } catch { result.missing.append(goal.title + ": не оценены выделенные средства") }
        }
        result.earmarkedEnding = earmarked
        let evidence = points.map { "\($0.event.id)|\($0.event.date)|\($0.event.remaining.map(String.init) ?? "unknown")|\($0.event.currency)|\($0.balance)|\($0.event.incomplete == true)" }.joined(separator:"\n") + "|\(reserve)|\(earmarked)|" + result.missing.joined(separator:";")
        result.calculationID += "." + VaultCrypto.fingerprint(Data(evidence.utf8))
        return result
    }
    public static func scenario(_ scenario: PlanScenario, db: Database, through: Day, financeEvents: [FinanceEvent]? = nil) throws -> PlanningProjection {
        guard (-365...1825).contains(scenario.projectDelayDays ?? 0),(0...200).contains(scenario.goalMonthlyPercent ?? 100) else { throw BudgetError.invalid("Параметры сценария вне диапазона.") }
        var draft = db; draft.planningData.flows = scenario.flows; draft.planningData.reserve = scenario.reserve; draft.planningData.reserveCurrency = scenario.currency
        let delay = scenario.projectDelayDays ?? 0
        for i in draft.projects.indices { guard var details = draft.projects[i].details else { continue }
            for j in details.costs.indices where details.costs[j].dueOn >= .today { details.costs[j].dueOn = details.costs[j].dueOn.adding(delay) }
            draft.projects[i].details = details
        }
        for i in draft.planningData.goals.indices { draft.planningData.goals[i].monthly = try FinanceMath.rounded(Money.divide(Money.multiply(Decimal(draft.planningData.goals[i].monthly),Decimal(scenario.goalMonthlyPercent ?? 100)),100)) }
        try PlanningLedger.validate(draft)
        var result = try projection(db:draft,through:through,financeEvents:financeEvents)
        result.assumptions.append("Черновик: сроки несвязанных проектных позиций сдвинуты на \(delay) дней; накопления \(scenario.goalMonthlyPercent ?? 100)%")
        if scenario.snapshotRevision != (db.revision ?? 0) { result.assumptions.append("Сохранённый план потоков относится к другой ревизии; текущие факты и договоры сохранены") }
        return result
    }
    public static func savings(_ goal: SavingsGoal, asOf: Day = .today) throws -> SavingsProjection {
        let remaining = max(0,goal.target - goal.allocated)
        let months = max(1,(Int(goal.dueOn.rawValue.prefix(4))! - Int(asOf.rawValue.prefix(4))!) * 12 + Int(goal.dueOn.rawValue.dropFirst(5).prefix(2))! - Int(asOf.rawValue.dropFirst(5).prefix(2))! + 1)
        let required = remaining / Int64(months) + (remaining % Int64(months) == 0 ? 0 : 1)
        let count = goal.monthly == 0 ? nil : remaining / goal.monthly + (remaining % goal.monthly == 0 ? 0 : 1)
        let date = remaining == 0 ? asOf : try count.flatMap { $0 <= 6000 ? try FinanceMath.addingMonths(asOf,Int($0 - 1)) : nil }
        return SavingsProjection(requiredMonthly:required,achievableOn:date,remaining:remaining)
    }
}
