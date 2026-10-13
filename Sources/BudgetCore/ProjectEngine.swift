import Foundation

public struct ProjectSummary: Equatable, Sendable {
    public var paid: Int64; public var contractedRemaining: Int64; public var uncommitted: Int64; public var reserve: Int64; public var forecast: Int64; public var income: Int64; public var userPaid: Int64
}
public struct BusinessProjection: Equatable, Sendable {
    public var monthlyResult: Int64; public var breakEvenRevenue: Int64?; public var paybackMonths: Int64?; public var notes: [String]
}
public enum ProjectEngine {
    public static func factAmount(_ fact: ProjectFact, db: Database) -> Int64 {
        guard fact.confirmed else { return 0 }
        if let id = fact.operationID { return min(fact.amount, db.operations.first { $0.id == id }?.amount ?? 0) }
        return fact.amount
    }
    public static func externalPaid(paymentID: UUID, db: Database) throws -> Int64 {
        var total: Int64 = 0
        for p in db.projects { guard let d = p.details else { continue }
            let costs = Set(d.costs.filter { $0.scheduledPaymentID == paymentID }.map(\.id))
            for f in d.facts where f.operationID == nil && f.effectiveKind == .expense && f.confirmed && f.costID.map(costs.contains) == true { total = try Money.add(total,f.amount) }
        }
        return total
    }
    public static func paid(cost: ProjectCost, details: ProjectDetails, db: Database) throws -> Int64 {
        if let id = cost.scheduledPaymentID, let payment = (db.financeData.scheduledPayments ?? []).first(where: { $0.id == id }) { return try ScheduledPayments.paid(payment,db:db) }
        return try details.facts.filter { $0.costID == cost.id && $0.effectiveKind == .expense }.reduce(0) { try Money.add($0,factAmount($1,db:db)) }
    }
    public static func summary(project: Project, db: Database) throws -> ProjectSummary {
        let d = project.details ?? ProjectDetails(); var paid: Int64 = 0, user: Int64 = 0, income: Int64 = 0, contracted: Int64 = 0, uncommitted: Int64 = 0
        let linked = Set(d.facts.compactMap(\.operationID))
        let reimbursementPayments = Set(d.facts.compactMap(\.reimbursementPaymentID))
        let reimbursements = (db.financeData.scheduledPayments ?? []).filter { reimbursementPayments.contains($0.id) }
        let reimbursementOperations = Set(reimbursements.flatMap { $0.allocations.map(\.operationID) })
        for payment in reimbursements { for allocation in payment.allocations where !linked.contains(allocation.operationID) { user = try Money.add(user,allocation.amount) } }
        for f in d.facts {
            let amount = factAmount(f,db:db)
            if f.effectiveKind == .revenue { income = try Money.add(income,amount) } else if f.effectiveKind == .expense { paid = try Money.add(paid,amount) }
            if [.expense,.reimbursement].contains(f.effectiveKind), f.participantID == nil || d.participants.first(where: { $0.id == f.participantID })?.isUser == true { user = try Money.add(user,amount) }
        }
        for o in db.operations where o.projectID == project.id && o.kind.isFlow && !linked.contains(o.id) {
            let a = try db.account(o.accountID), amount: Int64
            if a.currency == d.currency { amount = o.amount }
            else { guard let rate = try Reports.rate(from:a.currency,to:d.currency,rates:o.fx,on:o.date) else { throw BudgetError.missing("Нет исторического курса проекта") }; amount = try Money.convert(o.amount,from:a.currency,to:d.currency,rate:rate) }
            if o.kind == .expense { if !reimbursementOperations.contains(o.id) { paid = try Money.add(paid,amount); user = try Money.add(user,amount) } } else { income = try Money.add(income,amount) }
        }
        for c in d.costs {
            let remaining = max(0,c.amount - (try self.paid(cost:c,details:d,db:db)))
            if c.contracted { contracted = try Money.add(contracted,remaining) } else { uncommitted = try Money.add(uncommitted,remaining) }
        }
        let forecast = try Money.add(try Money.add(try Money.add(paid,contracted),uncommitted),d.reserve)
        return ProjectSummary(paid:paid,contractedRemaining:contracted,uncommitted:uncommitted,reserve:d.reserve,forecast:forecast,income:income,userPaid:user)
    }
    public static func splitIncome(_ amount: Int64, participants: [ProjectParticipant]) throws -> [(UUID,Int64)] {
        guard amount >= 0 else { throw BudgetError.invalid("Отрицательная сумма распределения.") }
        let values = try participants.compactMap { p -> (UUID,Decimal)? in guard let v = p.incomePercent else { return nil }; return (p.id,try Money.decimal(v)) }
        let total = values.reduce(Decimal(0)) { $0 + $1.1 }; guard total <= 100, values.allSatisfy({ $0.1 >= 0 }) else { throw BudgetError.invalid("Неверные доли.") }
        let target = try FinanceMath.rounded(Money.divide(Money.multiply(Decimal(amount),total),100)); var distributed: Int64 = 0
        return try values.enumerated().map { index, value in
            let part = index == values.count - 1 ? target - distributed : min(target - distributed,try FinanceMath.rounded(Money.divide(Money.multiply(Decimal(amount),value.1),100)))
            distributed = try Money.add(distributed,part); return (value.0,part)
        }
    }
    public static func business(_ model: BusinessModel) throws -> BusinessProjection {
        guard [model.initial,model.revenue,model.fixed,model.variable,model.tax].allSatisfy({ $0 >= 0 }) else { throw BudgetError.invalid("Отрицательные входы бизнеса.") }
        let cost = try Money.add(try Money.add(model.fixed,model.variable),model.tax), result = try Money.add(model.revenue,-cost)
        let contribution = model.revenue - model.variable
        let breakEven = contribution > 0 ? try FinanceMath.rounded(Money.divide(Money.multiply(Decimal(try Money.add(model.fixed,model.tax)),Decimal(model.revenue)),Decimal(contribution))) : nil
        let required = result > 0 ? model.initial / result + (model.initial % result == 0 ? 0 : 1) : nil
        let payback = required.flatMap { $0 <= Int64(model.horizonMonths ?? 60) ? $0 : nil }
        return BusinessProjection(monthlyResult:result,breakEvenRevenue:breakEven,paybackMonths:payback,notes:["Месячная модель постоянных/переменных затрат", "Налог: " + model.taxBasis, "Возврат вложений при постоянном результате; без неуказанных начислений"])
    }
    public static func loanSchedule(_ loan: ProjectLoan, prepayments: [ProjectPrepayment]? = nil) throws -> [ProjectLoanRow] {
        if !loan.manual.isEmpty {
            guard prepayments == nil || prepayments!.isEmpty else { throw BudgetError.invalid("После досрочного погашения внесите уточнённый банковский график; исходный ручной график не пересчитывается автоматически.") }
            let rows = loan.manual.sorted { $0.date < $1.date }; var debt = loan.principal
            guard Set(rows.map(\.date)).count == rows.count else { throw BudgetError.invalid("Даты ручного графика повторяются.") }
            for row in rows {
                let paid = try Money.add(row.principal,row.extra)
                guard paid >= 0,row.interest >= 0,paid <= debt else { throw BudgetError.invalid("Неверная строка ручного графика.") }; debt -= paid
                guard row.remaining == debt else { throw BudgetError.invalid("Остаток ручного графика не совпадает с погашением тела.") }
            }
            guard debt == 0 else { throw BudgetError.invalid("Ручной график неполный: остаётся тело долга.") }; return rows
        }
        guard (1...600).contains(loan.months), loan.principal > 0 else { throw BudgetError.invalid("Задайте положительную сумму и срок до 600 месяцев.") }
        var rate = try Money.divide(Money.decimal(loan.annualPercent),1200)
        guard rate >= 0 else { throw BudgetError.invalid("Отрицательная ставка.") }
        var remaining = loan.principal, level = try FinanceMath.annuity(principal:remaining,monthlyRate:rate,periods:loan.months)
        var principalPart = remaining / Int64(loan.months) + (remaining % Int64(loan.months) == 0 ? 0 : 1)
        let extras = (prepayments ?? loan.prepayments).sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        let changes = (loan.rateChanges ?? []).sorted { $0.date < $1.date }
        guard Set(changes.map(\.date)).count == changes.count else { throw BudgetError.invalid("Повторные даты изменения ставки.") }
        var rows: [ProjectLoanRow] = [], extraIndex = 0,rateIndex = 0
        var previous = try FinanceMath.addingMonths(loan.firstPayment,-1)
        guard extras.allSatisfy({ $0.amount > 0 && $0.date >= previous && $0.mode != .manual }) else { throw BudgetError.invalid("Проверьте даты/суммы досрочных погашений. Для ручного режима нужен банковский график.") }
        for index in 0..<loan.months {
            if remaining == 0 { break }; try Task.checkCancellation()
            let date = try FinanceMath.addingMonths(loan.firstPayment,index), days = max(1,FinanceMath.days(previous,date))
            var segment = previous, interestDecimal = Decimal(0), reducePayment = false, rateChanged = false
            while segment <= date {
                let extraDate = extraIndex < extras.count ? extras[extraIndex].date : date
                let rateDate = rateIndex < changes.count ? changes[rateIndex].date : date
                let eventDate = max(segment,min(date,min(extraDate,rateDate)))
                interestDecimal += try Money.divide(Money.multiply(Money.multiply(Decimal(remaining),rate),Decimal(max(0,FinanceMath.days(segment,eventDate)))),Decimal(days))
                segment = eventDate; var acted = false
                if rateIndex < changes.count && changes[rateIndex].date <= eventDate {
                    rate = try Money.divide(Money.decimal(changes[rateIndex].annualPercent),1200); guard rate >= 0 else { throw BudgetError.invalid("Отрицательная ставка.") }; rateIndex += 1; rateChanged = true; acted = true
                }
                if extraIndex < extras.count && extras[extraIndex].date <= eventDate && remaining > 0 {
                    let e = extras[extraIndex],paid = min(remaining,e.amount); remaining -= paid
                    let interest = remaining == 0 ? try FinanceMath.rounded(interestDecimal) : 0
                    rows.append(ProjectLoanRow(date:e.date,principal:0,interest:interest,extra:paid,remaining:remaining))
                    if remaining == 0 { interestDecimal = 0 }
                    reducePayment = reducePayment || e.mode == .reducePayment; extraIndex += 1; acted = true
                }
                if eventDate == date && !acted { break }; if remaining == 0 { break }
            }
            let interest = try FinanceMath.rounded(interestDecimal)
            if rateChanged, remaining > 0 {
                level = try FinanceMath.annuity(principal:remaining,monthlyRate:rate,periods:max(1,loan.months-index))
                principalPart = remaining / Int64(max(1,loan.months-index)) + (remaining % Int64(max(1,loan.months-index)) == 0 ? 0 : 1)
            }
            let principal: Int64
            if remaining == 0 { principal = 0 }
            else if index == loan.months - 1 { principal = remaining }
            else if loan.differentiated { principal = min(remaining,principalPart) }
            else { guard level > interest else { throw BudgetError.invalid("Платёж не покрывает проценты.") }; principal = min(remaining,level-interest) }
            remaining -= principal; if principal > 0 || interest > 0 { rows.append(ProjectLoanRow(date:date,principal:principal,interest:interest,remaining:remaining)) }
            if reducePayment && remaining > 0 {
                let periods = max(1,loan.months-index-1)
                level = try FinanceMath.annuity(principal:remaining,monthlyRate:rate,periods:periods)
                principalPart = remaining / Int64(periods) + (remaining % Int64(periods) == 0 ? 0 : 1)
            }
            previous = date
        }
        guard remaining == 0 else { throw BudgetError.invalid("График не закрывает задолженность.") }
        // Multiple payments on one date share one deterministic calendar row.
        var grouped: [Day:ProjectLoanRow] = [:]
        for r in rows { if let old = grouped[r.date] { grouped[r.date] = ProjectLoanRow(date:r.date,principal:try Money.add(old.principal,r.principal),interest:try Money.add(old.interest,r.interest),extra:try Money.add(old.extra,r.extra),remaining:r.remaining) } else { grouped[r.date] = r } }
        return grouped.values.sorted { $0.date < $1.date }
    }
}
