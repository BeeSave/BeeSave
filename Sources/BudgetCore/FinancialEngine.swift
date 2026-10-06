import Foundation
import CryptoKit

private struct FinanceBalanceTimeline {
    let values: [(Day, Int64)]
    init(accountID: UUID, db: Database) throws {
        let records = db.operations.filter { $0.accountID == accountID || $0.toAccountID == accountID }.sorted { $0.date < $1.date }
        var running: Int64 = 0, rows: [(Day, Int64)] = []
        for record in records { running = try Money.add(running, record.posting(for: accountID)); if rows.last?.0 == record.date { rows[rows.count - 1].1 = running } else { rows.append((record.date, running)) } }
        values = rows
    }
    func balance(on day: Day) -> Int64 {
        var low = 0, high = values.count
        while low < high { let mid = (low + high) / 2; if values[mid].0 <= day { low = mid + 1 } else { high = mid } }
        return low == 0 ? 0 : values[low - 1].1
    }
}
private struct FinanceDebtTimeline {
    let points: [DebtTimelinePoint]
    init(accountID: UUID, db: Database) throws { points = try FinancialLedger.debtTimeline(accountID: accountID, db: db) }
    func amount(_ component: FinancialComponent, on day: Day) -> Int64 {
        var low = 0, high = points.count
        while low < high { let mid = (low + high) / 2; if points[mid].date <= day { low = mid + 1 } else { high = mid } }
        return low == 0 ? 0 : points[low - 1].components[component] ?? 0
    }
}
public struct CreditCostScenario: Equatable, Sendable {
    public var interest: Int64?; public var fees: Int64; public var total: Int64?; public var accuracy: ForecastAccuracy; public var notes: [String]
}
public struct LoanScenario: Equatable, Sendable {
    public var events: [FinanceEvent]; public var remainingInterest: Int64?; public var fee: Int64?; public var end: Day?; public var accuracy: ForecastAccuracy
}
public struct DepositExitScenario: Equatable, Sendable {
    public var principal: Int64
    public var recomputedInterest: Int64?
    public var previouslyPaidInterest: Int64
    public var interestAdjustment: Int64?
    public var fee: Int64
    public var returnBeforeNewTax: Int64?
    public var accuracy: ForecastAccuracy
    public var notes: [String]
}
public enum FinancialEngine {
    public static func eventKey(_ contractID: UUID, kind: FinanceEventKind, anchor: String) -> String {
        SHA256.hash(data: Data((contractID.uuidString + "|" + kind.rawValue + "|" + anchor).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func event(contract: FinancialContract, kind: FinanceEventKind, date: Day, accrualEnd: Day? = nil, anchor: String? = nil, components: [FinancialAllocation], amount: Int64?, balanceAfter: Int64? = nil, accuracy: ForecastAccuracy = .calculated, notes: [String] = [], db: Database) throws -> FinanceEvent {
        let key = eventKey(contract.id, kind: kind, anchor: anchor ?? (accrualEnd ?? date).rawValue)
        let covered = try db.financeData.fulfillments.filter { $0.eventID == key }.reduce(Int64(0)) { try Money.add($0, $1.amount) }
        return FinanceEvent(id: key, contractID: contract.id, kind: kind, date: date, accrualEnd: accrualEnd ?? date, components: components, amount: amount, remaining: amount.map { max(0, $0 - covered) }, balanceAfter: balanceAfter, accuracy: accuracy, notes: notes)
    }
    private static func shifted(_ date: Day, contract: FinancialContract, db: Database) throws -> (Day, [String]) {
        let calendar = db.financeData.calendars.first { $0.id == contract.calendarID }
        let result = try FinanceMath.shifted(date, rule: contract.businessDayRule, calendar: calendar)
        return (result.0, result.1 ? [] : ["Банковский календарь не покрывает дату; уточните день вручную."])
    }
    public static func events(db: Database, asOf: Day = .today) throws -> [FinanceEvent] {
        let operations = FinancialLedger.operationsByAccount(in: db)
        var rows: [FinanceEvent] = []
        for contract in db.financeData.contracts { var projection = db; projection.operations = operations[contract.accountID] ?? []; rows.append(contentsOf: try events(contract: contract, db: projection, asOf: asOf)) }
        return rows.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
    public static func events(contract: FinancialContract, db: Database, asOf: Day = .today) throws -> [FinanceEvent] {
        try Task.checkCancellation()
        guard contract.status == .active else { return [] }
        let horizon = try contract.end ?? FinanceMath.addingMonths(max(asOf, contract.start), contract.forecastMonths)
        var rows: [FinanceEvent]
        if contract.frequency == .manual || contract.terms(on: asOf)?.loan.method == .manual && contract.kind.isDebt {
            rows = try manualEvents(contract: contract, db: db, asOf: asOf)
        } else {
            switch contract.kind {
            case .deposit: rows = try depositEvents(contract: contract, db: db, asOf: asOf, horizon: horizon)
            case .revolvingCredit: rows = try creditEvents(contract: contract, db: db, asOf: asOf)
            case .termLoan, .mortgage: rows = try loanEvents(contract: contract, db: db, asOf: asOf, horizon: horizon)
            case .ordinary: return []
            }
            if !contract.manualRows.isEmpty {
                let manual = try manualEvents(contract: contract, db: db, asOf: asOf)
                for row in manual { rows.removeAll { $0.kind == row.kind && $0.date == row.date }; rows.append(row) }
            }
        }
        var dates = Set(rows.map { $0.kind.rawValue + $0.date.rawValue })
        for terms in contract.terms {
            for date in [terms.resetOn, terms.loan.fixedDealEnd].compactMap({ $0 }) where date >= contract.start && !dates.contains(FinanceEventKind.rateChange.rawValue + date.rawValue) {
                dates.insert(FinanceEventKind.rateChange.rawValue + date.rawValue)
                rows.append(try event(contract: contract, kind: .rateChange, date: date, components: [], amount: nil, accuracy: .incomplete, notes: ["Проверьте ставку и будущий график."], db: db))
            }
            if let date = terms.deposit.renewalDecisionOn, contract.kind == .deposit { rows.append(try event(contract: contract, kind: .renewalDecision, date: date, components: [], amount: nil, notes: ["Подтвердите возврат или условия пролонгации."], db: db)) }
        }
        return rows.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
    private static func manualEvents(contract: FinancialContract, db: Database, asOf: Day) throws -> [FinanceEvent] {
        var principal = contract.kind.isDebt ? try FinancialLedger.debt(accountID: contract.accountID, db: db, on: asOf).amount(.principal) : nil
        var rows: [FinanceEvent] = []
        for row in contract.manualRows.sorted(by: { $0.date < $1.date }) {
            try Task.checkCancellation()
            let sum = try row.components.reduce(Int64(0)) { try Money.add($0, $1.amount) }
            let amount = row.amount ?? (row.components.isEmpty ? nil : sum)
            if let p = principal, row.date > asOf { let reduction = row.components.filter { $0.component == .principal }.reduce(Int64(0)) { $0 + $1.amount }; principal = max(0, p - reduction) }
            rows.append(try event(contract: contract, kind: row.kind, date: row.date, anchor: row.id.uuidString, components: row.components, amount: amount, balanceAfter: principal, accuracy: row.components.isEmpty ? .incomplete : .calculated, notes: ["График банка / ручной ввод", row.comment].filter { !$0.isEmpty }, db: db))
        }
        if contract.kind.isDebt, let principal, principal > 0, let end = contract.end, rows.last?.balanceAfter != 0 {
            rows.append(try event(contract: contract, kind: .loanPayment, date: end, anchor: "residual", components: [FinancialAllocation(.principal, principal)], amount: principal, balanceAfter: 0, accuracy: .incomplete, notes: ["В ручном графике осталось непокрытое тело; подтвердите финальный платёж."], db: db))
        }
        return rows
    }
    private static func rawDaily(principal: Decimal, terms: FinancialTerms, date: Day, rateCache: inout [String: Decimal]) throws -> Decimal? {
        guard let annual = try terms.rate() else { return nil }
        let year = FinanceMath.year(date), denominator = terms.basis == .actual360 ? 360 : terms.basis == .actualActual && FinanceMath.leap(year) ? 366 : 365
        let rate: Decimal
        if terms.rateKind == .effectiveAnnual {
            let key = terms.id.uuidString + "|" + String(denominator)
            if let value = rateCache[key] { rate = value } else { let value = try FinanceMath.root(1 + annual, degree: denominator) - 1; rateCache[key] = value; rate = value }
        } else {
            if terms.rateKind == .periodic { return nil }
            rate = try Money.multiply(annual, FinanceMath.fraction(date, date.adding(1), basis: terms.basis))
        }
        if terms.deposit.tiers.isEmpty { return try Money.multiply(principal, rate) }
        let tiers = terms.deposit.tiers.sorted { $0.lowerMinor < $1.lowerMinor }
        func tierRate(_ percent: String) throws -> Decimal {
            let annual = try Money.decimal(percent) / 100
            if terms.rateKind == .effectiveAnnual { return try FinanceMath.root(1 + annual, degree: denominator) - 1 }
            return try Money.multiply(annual, FinanceMath.fraction(date, date.adding(1), basis: terms.basis))
        }
        if terms.deposit.tierMethod == .wholeBalance {
            let selected = tiers.last { Decimal($0.lowerMinor) <= principal }; guard let selected else { return try Money.multiply(principal, rate) }
            return try Money.multiply(principal, tierRate(selected.annualPercent))
        }
        var value = Decimal(0)
        for (index, tier) in tiers.enumerated() {
            let upper = index + 1 < tiers.count ? Decimal(tiers[index + 1].lowerMinor) : principal
            let portion = max(0, min(principal, upper) - Decimal(tier.lowerMinor))
            value += try Money.multiply(portion, tierRate(tier.annualPercent))
        }
        return value
    }
    private static func accrue(contract: FinancialContract, start originalStart: Day, end originalEnd: Day, constantPrincipal: Int64? = nil, principal: (Day, FinancialTerms) throws -> Int64) throws -> (Int64?, ForecastAccuracy, [String]) {
        let raw = try accrueRaw(contract: contract, start: originalStart, end: originalEnd, constantPrincipal: constantPrincipal.map(Decimal.init)) { try Decimal(principal($0, $1)) }
        let rounding = contract.terms(on: originalStart)?.rounding ?? .halfUp
        return (try raw.0.map { try FinanceMath.rounded($0, mode: rounding) }, raw.1, raw.2)
    }
    private static func accrueRaw(contract: FinancialContract, start originalStart: Day, end originalEnd: Day, constantPrincipal: Decimal? = nil, principal: (Day, FinancialTerms) throws -> Decimal) throws -> (Decimal?, ForecastAccuracy, [String]) {
        guard let initial = contract.terms(on: originalStart) else { return (nil, .incomplete, ["Нет условий начала периода."]) }
        let start = initial.includeFirstDay ? originalStart : originalStart.adding(1)
        let end = initial.includeLastDay ? originalEnd.adding(1) : originalEnd
        guard end >= start else { return (0, .calculated, []) }
        if initial.basis == .equalMonths || initial.rateKind == .periodic {
            guard let rate = try FinanceMath.monthlyRate(initial) else { return (nil, .incomplete, ["Введите ставку начисления; APY/APR не заменяют её."]) }
            let months = (FinanceMath.year(originalEnd) - FinanceMath.year(originalStart)) * 12 + FinanceMath.month(originalEnd) - FinanceMath.month(originalStart)
            let sameAnchor = FinanceMath.day(originalStart) == FinanceMath.day(originalEnd) || originalEnd == originalEnd.lastOfMonth
            let factor = initial.rateKind == .periodic ? Decimal(1) : Decimal(max(1, months))
            let amount = try Money.multiply(Money.multiply(principal(start, initial), rate), factor)
            let rateChanges = contract.terms.contains { $0.effectiveFrom > start && $0.effectiveFrom < end }
            return (amount, (!sameAnchor || rateChanges) ? .scenario : initial.scenarioRate ? .scenario : .calculated, (!sameAnchor || rateChanges) ? ["Нерегулярный период / смена ставки: подтвердите сумму по графику банка."] : [])
        }
        if let constantPrincipal, initial.rateKind == .nominalAnnual, [.actual365, .actual360, .actualActual].contains(initial.basis), initial.roundingPoint == .event, initial.deposit.tiers.isEmpty, !contract.terms.contains(where: { $0.effectiveFrom > start && $0.effectiveFrom < end }) {
            guard let rate = try initial.rate() else { return (nil, .incomplete, ["Неизвестна ставка."]) }
            let amount = try Money.multiply(constantPrincipal, Money.multiply(rate, FinanceMath.fraction(start, end, basis: initial.basis)))
            return (amount, initial.scenarioRate ? .scenario : .calculated, [])
        }
        var cursor = start, total = Decimal(0), rateCache: [String: Decimal] = [:], accuracy = ForecastAccuracy.calculated
        while cursor < end {
            try Task.checkCancellation()
            guard let terms = contract.terms(on: cursor), let raw = try rawDaily(principal: principal(cursor, terms), terms: terms, date: cursor, rateCache: &rateCache) else { return (nil, .incomplete, ["Неизвестная ставка / база начисления; задайте сумму вручную."]) }
            total += terms.roundingPoint == .daily ? Decimal(try FinanceMath.rounded(raw, mode: terms.rounding)) : raw
            if terms.scenarioRate { accuracy = .scenario }; cursor = cursor.adding(1)
        }
        return (total, accuracy, [])
    }
    private static func depositEvents(contract: FinancialContract, db: Database, asOf: Day, horizon: Day) throws -> [FinanceEvent] {
        if contract.terms.contains(where: { $0.deposit.accrualFrequency != nil || $0.deposit.capitalizationFrequency != nil || $0.deposit.roundOnlyAtFinalPayout == true }) {
            return try separatedDepositEvents(contract: contract, db: db, asOf: asOf, horizon: horizon)
        }
        let account = try db.account(contract.accountID), timeline = try FinanceBalanceTimeline(accountID: contract.accountID, db: db)
        let beginning = max(contract.start, account.openedOn)
        let dates = try FinanceMath.paymentDates(contract, through: horizon).filter { $0 > beginning }
        var cursor = beginning, virtualCapital: Int64 = 0, rows: [FinanceEvent] = []
        for originalDate in dates {
            try Task.checkCancellation()
            let transferDate = try shifted(originalDate, contract: contract, db: db)
            let accrualEnd = contract.shiftAccrualWithPayment ? transferDate.0 : originalDate
            let minimum = timeline.values.filter { $0.0 >= cursor && $0.0 < accrualEnd }.map(\.1).min().map { min($0, timeline.balance(on: cursor)) } ?? timeline.balance(on: cursor)
            let earned = try accrue(contract: contract, start: cursor, end: accrualEnd) { day, terms in
                let actual = terms.balanceBasis == .minimumPeriod ? minimum : timeline.balance(on: terms.balanceBasis == .openingDay ? day.adding(-1) : day)
                return max(0, try Money.add(actual, virtualCapital))
            }
            let terms = contract.terms(on: originalDate) ?? contract.terms.last!
            var notes = earned.2 + transferDate.1
            let violation = db.operations.contains { ($0.accountID == contract.accountID || $0.toAccountID == contract.accountID) && $0.date <= originalDate && $0.financial?.consequenceUnknown == true }
            if violation { notes.append("Есть движение с неизвестными последствиями для условий депозита.") }
            if !terms.deposit.taxKnown { notes.append("До налога; налог не рассчитан.") }
            var components: [FinancialAllocation] = []
            if let amount = earned.0 { components.append(FinancialAllocation(.interest, amount)) }
            let row = try event(contract: contract, kind: .depositInterest, date: transferDate.0, accrualEnd: originalDate, components: components, amount: earned.0, accuracy: transferDate.1.isEmpty && !violation ? earned.1 : .incomplete, notes: notes, db: db)
            rows.append(row)
            if originalDate > asOf, terms.deposit.capitalize, let amount = row.remaining {
                let tax = try terms.deposit.taxAmount ?? terms.deposit.taxPercent.map { try FinanceMath.rounded(Decimal(amount) * Money.decimal($0) / 100) } ?? 0
                virtualCapital = try Money.add(virtualCapital, max(0, amount - tax))
            }
            cursor = accrualEnd
        }
        if let end = contract.end {
            let amount = max(0, try Money.add(timeline.balance(on: min(end, asOf)), virtualCapital))
            let shift = try shifted(end, contract: contract, db: db)
            rows.append(try event(contract: contract, kind: .depositMaturity, date: shift.0, accrualEnd: end, components: [FinancialAllocation(.principal, amount)], amount: amount, balanceAfter: 0, accuracy: shift.1.isEmpty ? .calculated : .incomplete, notes: shift.1 + ["Возврат не подтверждается автоматически."], db: db))
        }
        return rows
    }
    private static func separatedDepositEvents(contract: FinancialContract, db: Database, asOf: Day, horizon: Day) throws -> [FinanceEvent] {
        let account = try db.account(contract.accountID), timeline = try FinanceBalanceTimeline(accountID: contract.accountID, db: db)
        let beginning = max(contract.start, account.openedOn)
        guard let initial = contract.terms(on: beginning) else { return [] }
        let accrualFrequency = initial.deposit.accrualFrequency ?? contract.frequency
        let capitalizationFrequency = initial.deposit.capitalizationFrequency ?? accrualFrequency
        func dates(_ frequency: PaymentFrequency) throws -> Set<Day> {
            var schedule = contract; schedule.frequency = frequency
            if frequency != contract.frequency { schedule.firstPayment = nil }
            return Set(try FinanceMath.paymentDates(schedule, through: horizon).filter { $0 > beginning })
        }
        let accrualDates = try dates(accrualFrequency), payouts = try dates(contract.frequency)
        let capitalizationDates = initial.deposit.capitalize ? try dates(capitalizationFrequency) : []
        let boundaries = accrualDates.union(payouts).union(capitalizationDates).sorted()
        var cursor = beginning, capital = Decimal(0), awaitingCapitalization = Decimal(0), awaitingPayout = Decimal(0), rows: [FinanceEvent] = []
        var accuracy = ForecastAccuracy.calculated, notes: [String] = [], known = true
        let deferred = capitalizationFrequency != contract.frequency
        if initial.deposit.capitalize && !payouts.isSubset(of: capitalizationDates) { known = false; accuracy = .incomplete; notes.append("Выплата до капитализации требует отдельного банковского правила / ручного графика.") }
        if deferred && initial.deposit.capitalize && (initial.deposit.taxAmount ?? 0 > 0 || initial.deposit.taxPercent != nil) { known = false; accuracy = .incomplete; notes.append("Уточните период удержания налога относительно расчётной капитализации.") }
        for date in boundaries {
            try Task.checkCancellation()
            guard let terms = contract.terms(on: cursor) else { known = false; continue }
            let changedCadence = terms.deposit.accrualFrequency != initial.deposit.accrualFrequency || terms.deposit.capitalizationFrequency != initial.deposit.capitalizationFrequency || terms.deposit.roundOnlyAtFinalPayout != initial.deposit.roundOnlyAtFinalPayout || terms.deposit.capitalize != initial.deposit.capitalize
            let shift = try shifted(date, contract: contract, db: db)
            let end = contract.shiftAccrualWithPayment && payouts.contains(date) ? shift.0 : date
            let minimum = timeline.values.filter { $0.0 >= cursor && $0.0 < end }.map(\.1).min().map { min($0, timeline.balance(on: cursor)) } ?? timeline.balance(on: cursor)
            let earned = try accrueRaw(contract: contract, start: cursor, end: end) { day, conditions in
                let balance = conditions.balanceBasis == .minimumPeriod ? minimum : timeline.balance(on: conditions.balanceBasis == .openingDay ? day.adding(-1) : day)
                return max(0, Decimal(balance) + capital)
            }
            if changedCadence || earned.0 == nil || (earned.1 == .scenario && (terms.basis == .equalMonths || terms.rateKind == .periodic)) {
                known = false; accuracy = .incomplete; notes.append("Изменение периодов / нерегулярное начисление требует графика банка.")
            } else if let raw = earned.0 { awaitingCapitalization += raw; awaitingPayout += raw }
            if earned.1 != .calculated { accuracy = earned.1 == .incomplete ? .incomplete : accuracy == .incomplete ? .incomplete : .scenario }
            notes += earned.2 + shift.1
            if !shift.1.isEmpty { accuracy = .incomplete }
            if capitalizationDates.contains(date), known {
                let compounded = initial.deposit.roundOnlyAtFinalPayout == true ? awaitingCapitalization : Decimal(try FinanceMath.rounded(awaitingCapitalization, mode: terms.rounding))
                awaitingPayout += compounded - awaitingCapitalization
                if date > asOf || deferred {
                    let tax: Decimal
                    if !deferred { tax = Decimal(try terms.deposit.taxAmount ?? terms.deposit.taxPercent.map { try FinanceMath.rounded(compounded * Money.decimal($0) / 100) } ?? 0) }
                    else { tax = 0 }
                    capital += max(0, compounded - tax)
                }
                awaitingCapitalization = 0
            }
            if payouts.contains(date) {
                let amount = known ? try FinanceMath.rounded(awaitingPayout, mode: terms.rounding) : nil
                let violation = db.operations.contains { ($0.accountID == contract.accountID || $0.toAccountID == contract.accountID) && $0.date <= date && $0.financial?.consequenceUnknown == true }
                if violation { accuracy = .incomplete; notes.append("Есть движение с неизвестными последствиями для условий депозита.") }
                if !terms.deposit.taxKnown { notes.append("До налога; налог не рассчитан.") }
                notes.append("Начисление: " + accrualFrequency.title + "; капитализация: " + (initial.deposit.capitalize ? capitalizationFrequency.title : "Нет") + "; выплата: " + contract.frequency.title + ".")
                notes.append(initial.deposit.roundOnlyAtFinalPayout == true ? "Расчётная капитализация без округления; округление только финальной выплаты." : "Округление при капитализации / выплате.")
                let row = try event(contract: contract, kind: .depositInterest, date: shift.0, accrualEnd: date, components: amount.map { [FinancialAllocation(.interest, $0)] } ?? [], amount: amount, accuracy: accuracy, notes: Array(Set(notes)).sorted(), db: db)
                rows.append(row)
                if date <= asOf || !initial.deposit.capitalize { capital = 0 }
                awaitingPayout = 0; awaitingCapitalization = 0; notes = []
            }
            cursor = end
        }
        if let end = contract.end {
            let shift = try shifted(end, contract: contract, db: db), rounding = contract.terms(on: end)?.rounding ?? initial.rounding
            let amount = known ? try FinanceMath.rounded(max(0, Decimal(timeline.balance(on: min(end, asOf))) + capital), mode: rounding) : nil
            rows.append(try event(contract: contract, kind: .depositMaturity, date: shift.0, accrualEnd: end, components: amount.map { [FinancialAllocation(.principal, $0)] } ?? [], amount: amount, balanceAfter: 0, accuracy: shift.1.isEmpty ? accuracy : .incomplete, notes: shift.1 + ["Возврат не подтверждается автоматически."], db: db))
        }
        return rows
    }
    private static func loanEvents(contract: FinancialContract, db: Database, asOf: Day, horizon: Day, scenarioPrincipal: Int64? = nil, reduceTermPayment: Int64? = nil, considerRecordedPrepayments: Bool = true, recalculatePaymentAfter: Day? = nil) throws -> [FinanceEvent] {
        let account = try db.account(contract.accountID)
        var heldPayment = reduceTermPayment, prepaymentNote: String?, recalculateAfter = recalculatePaymentAfter, schedule = contract
        if considerRecordedPrepayments, let recorded = db.operations.filter({ $0.toAccountID == contract.accountID && $0.date <= asOf && $0.financial?.prepayment == true }).max(by: { $0.date == $1.date ? $0.createdAt < $1.createdAt : $0.date < $1.date }) {
            if let end = recorded.financial?.prepaymentScheduleEnd { schedule.end = min(schedule.end ?? end, end) }
            switch recorded.financial?.prepaymentMode {
            case .reduceTerm:
                heldPayment = recorded.financial?.prepaymentRegularPayment
                if heldPayment == nil { prepaymentNote = "Неизвестен платёж до досрочного погашения; уточните будущий график банка." }
            case .reducePayment: recalculateAfter = recorded.date
            case .manual, nil: prepaymentNote = "После досрочного погашения укажите выбранный режим или график банка." }
        }
        let summary = try FinancialLedger.debt(accountID: contract.accountID, db: db, on: asOf)
        let dates = try FinanceMath.paymentDates(schedule, through: horizon).filter { $0 >= account.openedOn }
        var principal = scenarioPrincipal ?? summary.amount(.principal), cursor = max(contract.start, account.openedOn), rows: [FinanceEvent] = []
        var payment: Int64?, paymentTermsID: UUID?, enteredFuture = false
        let actualDebt = try FinanceDebtTimeline(accountID: contract.accountID, db: db)
        for (index, originalDate) in dates.enumerated() {
            try Task.checkCancellation()
            guard let terms = contract.terms(on: cursor) ?? contract.terms(on: originalDate) else { continue }
            let shift = try shifted(originalDate, contract: contract, db: db), end = contract.shiftAccrualWithPayment ? shift.0 : originalDate
            let future = originalDate > asOf
            if future && !enteredFuture { principal = scenarioPrincipal ?? summary.amount(.principal); payment = nil; paymentTermsID = nil; enteredFuture = true }
            if !future { principal = actualDebt.amount(.principal, on: originalDate.adding(-1)) }
            if future && principal == 0 { break }
            let remainingCount = max(1, dates.count - index)
            let retainedPayment = future ? heldPayment : nil
            let bankOverride = future && recalculateAfter.map({ terms.effectiveFrom <= $0 }) == true ? nil : terms.loan.paymentOverride
            if paymentTermsID != terms.id || payment == nil {
                if let rate = try FinanceMath.monthlyRate(terms), terms.basis == .equalMonths, contract.frequency == .monthly {
                    payment = try bankOverride ?? retainedPayment ?? FinanceMath.annuity(principal: principal, monthlyRate: rate, periods: remainingCount, rounding: terms.rounding)
                } else if let override = bankOverride { payment = override }
                else if terms.rateKind == .nominalAnnual {
                    var start = cursor, rates: [Decimal] = [], known = true
                    for date in dates[index...] {
                        guard let conditions = contract.terms(on: start), let annual = try conditions.rate(), conditions.rateKind == .nominalAnnual, !contract.terms.contains(where: { $0.effectiveFrom > start && $0.effectiveFrom < date }) else { known = false; break }
                        let first = conditions.includeFirstDay ? start : start.adding(1), last = conditions.includeLastDay ? date.adding(1) : date
                        rates.append(try Money.multiply(annual, FinanceMath.fraction(first, last, basis: conditions.basis)))
                        start = date
                    }
                    payment = known ? try (retainedPayment ?? FinanceMath.levelPayment(principal: principal, periodRates: rates, rounding: terms.rounding)) : nil
                } else { payment = nil }
                paymentTermsID = terms.id
            }
            let interest = try accrue(contract: contract, start: cursor, end: end, constantPrincipal: cursor > asOf ? principal : nil) { day, _ in
                if day <= asOf { return actualDebt.amount(.principal, on: day) }
                return principal
            }
            var accuracy = interest.1, notes = interest.2 + shift.1
            if future, let prepaymentNote { accuracy = .incomplete; notes.append(prepaymentNote) }
            if summary.amount(.unallocated) > 0 { accuracy = .incomplete; notes.append("Начальный долг / сверка не распределены.") }
            if !shift.1.isEmpty { accuracy = .incomplete }
            let holiday = terms.loan.holidayEnd.map { originalDate <= $0 } ?? false
            let interestOnly = terms.loan.method == .interestOnly || terms.loan.interestOnlyEnd.map { originalDate <= $0 } == true
            var reduction: Int64?
            if holiday { reduction = 0 }
            else if interestOnly { reduction = originalDate == schedule.end ? principal : 0 }
            else if terms.loan.method == .differentiated { reduction = try FinanceMath.rounded(Decimal(principal) / Decimal(remainingCount), mode: terms.rounding) }
            else if let payment, let interest = interest.0 { reduction = max(0, payment - interest) }
            else { accuracy = .incomplete; notes.append("Для аннуитета с этим периодом задайте платёж / банковский график.") }
            if let value = reduction { reduction = min(principal, value); if originalDate == schedule.end { reduction = principal } }
            var components: [FinancialAllocation] = []
            if let reduction { components.append(FinancialAllocation(.principal, reduction)) }
            if let interest = interest.0, !holiday || terms.loan.accrueDuringHoliday { components.append(FinancialAllocation(.interest, holiday && terms.loan.capitalizeDuringHoliday ? 0 : interest)) }
            if terms.loan.paymentFee > 0 { components.append(FinancialAllocation(.fee, terms.loan.paymentFee)) }
            if terms.loan.escrowPayment > 0 { components.append(FinancialAllocation(.escrow, terms.loan.escrowPayment)) }
            if holiday && terms.loan.capitalizeDuringHoliday, let interest = interest.0 { principal = try Money.add(principal, interest); accuracy = .scenario; notes.append("Проценты капитализируются по условию отсрочки.") }
            if let payment, let interest = interest.0, payment < interest && !holiday {
                notes.append("Платёж ниже процентов: проверьте отрицательную амортизацию.")
                if terms.loan.allowNegativeAmortization { principal = try Money.add(principal, interest - payment); accuracy = .scenario } else { accuracy = .incomplete }
            }
            if let reduction { principal -= reduction }
            let amount = interest.0 == nil || reduction == nil ? nil : try components.reduce(Int64(0)) { try Money.add($0, $1.amount) }
            rows.append(try event(contract: contract, kind: .loanPayment, date: shift.0, accrualEnd: originalDate, components: components, amount: amount, balanceAfter: principal, accuracy: accuracy, notes: notes, db: db))
            cursor = end
        }
        return rows
    }
    private static func creditEvents(contract: FinancialContract, db: Database, asOf: Day) throws -> [FinanceEvent] {
        guard let terms = contract.terms(on: asOf) else { return [] }
        var statements = db.financeData.statements.filter { $0.contractID == contract.id }
        if statements.isEmpty {
            var closed = try FinanceMath.addingMonths(asOf, 0, anchor: terms.credit.closingDay)
            if closed > asOf { closed = try FinanceMath.addingMonths(closed, -1, anchor: terms.credit.closingDay) }
            let account = try db.account(contract.accountID)
            if closed >= account.openedOn {
                let balance = try FinancialLedger.debt(accountID: contract.accountID, db: db, on: closed).debt
                let minimum: Int64
                switch terms.credit.minimumMode {
                case .fixed: minimum = min(balance, terms.credit.minimumFixed)
                case .percent, .percentPlusCharges:
                    let breakdown = try FinancialLedger.debt(accountID: contract.accountID, db: db, on: closed)
                    let base = terms.credit.minimumMode == .percentPlusCharges ? breakdown.amount(.principal) : balance
                    let extra = terms.credit.minimumMode == .percentPlusCharges ? balance - breakdown.amount(.principal) : 0
                    minimum = min(balance, max(terms.credit.minimumFloor, try Money.add(FinanceMath.rounded(Decimal(base) * Money.decimal(terms.credit.minimumPercent) / 100), extra)))
                case .manual: minimum = 0
                }
                var statement = CreditStatement(contractID: contract.id, start: try FinanceMath.addingMonths(closed, -1, anchor: terms.credit.closingDay).adding(1), closedOn: closed, dueOn: closed.adding(terms.credit.dueDays), balance: balance, minimum: minimum, graceAmount: balance); statement.source = "Расчёт BeeSave"; statements = [statement]
            }
        }
        var rows: [FinanceEvent] = []
        for statement in statements {
            let payments = db.operations.filter { $0.toAccountID == contract.accountID && $0.kind == .transfer && $0.date > statement.closedOn && $0.date <= asOf }
            let paid = try payments.reduce(Int64(0)) { try Money.add($0, $1.toAmount ?? 0) }
            let overlapping = payments.contains { payment in statements.contains { $0.id != statement.id && payment.date > $0.closedOn } }
            let notes = [statement.source] + (terms.credit.minimumMode == .manual && statement.source == "Расчёт BeeSave" ? ["Введите минимум из выписки."] : [])
            let anchor = statement.source == "Расчёт BeeSave" ? statement.closedOn.rawValue : statement.id.uuidString
            var minimum = try event(contract: contract, kind: .minimumPayment, date: statement.dueOn, anchor: anchor, components: [], amount: terms.credit.minimumMode == .manual && statement.source == "Расчёт BeeSave" ? nil : statement.minimum, notes: notes, db: db)
            let minimumExplicitlyCovered = minimum.isFulfilled
            minimum.remaining = minimum.amount.map { max(0, $0 - max(paid, ($0 - (minimum.remaining ?? $0)))) }
            if overlapping && !minimumExplicitlyCovered { minimum.remaining = nil; minimum.accuracy = .incomplete; minimum.notes.append("Платёж относится к нескольким выпискам. Уточните распределение по данным банка и свяжите факт с событием.") }
            rows.append(minimum)
            if terms.credit.grace != .none {
                let deadline = terms.credit.graceEnd ?? statement.dueOn
                var grace = try event(contract: contract, kind: .gracePayment, date: deadline, anchor: anchor, components: [], amount: statement.graceAmount, notes: notes + ["Минимум не заменяет сумму сохранения льготы."], db: db)
                let graceExplicitlyCovered = grace.isFulfilled
                let eligiblePaid = try db.operations.filter { $0.toAccountID == contract.accountID && $0.kind == .transfer && $0.date > statement.closedOn && $0.date <= asOf }.reduce(Int64(0)) { try Money.add($0, $1.toAmount ?? 0) }
                grace.remaining = min(grace.remaining ?? statement.graceAmount, max(0, statement.graceAmount - eligiblePaid))
                let candidates = db.operations.filter { $0.toAccountID == contract.accountID && $0.kind == .transfer && $0.date > statement.closedOn && $0.date <= min(asOf, deadline) }
                let onTime = try candidates.filter { creditedOnTime($0, contract: contract, deadline: deadline) == true }.reduce(Int64(0)) { try Money.add($0, $1.toAmount ?? 0) }
                let unknown = candidates.contains { creditedOnTime($0, contract: contract, deadline: deadline) == nil }
                if unknown { grace.remaining = nil; grace.accuracy = .incomplete; grace.notes.append("На дату дедлайна неизвестно время зачисления. Льгота не подтверждена; укажите банковское время платежа.") }
                else if asOf > deadline && onTime < statement.graceAmount { grace.notes.append("Льготный срок нарушен; поздняя оплата погашает долг, но не отменяет проценты.") }
                if terms.credit.requiresMinimumForGrace && grace.isFulfilled {
                    let minimumOnTime = try payments.filter { creditedOnTime($0, contract: contract, deadline: statement.dueOn) == true }.reduce(Int64(0)) { try Money.add($0, $1.toAmount ?? 0) }
                    if minimum.amount == nil || minimumOnTime < statement.minimum { grace.remaining = nil; grace.accuracy = .incomplete; grace.notes.append("Сумма льготы оплачена, но обязательный своевременный минимум не подтверждён. Уточните сохранение льготы по выписке.") }
                }
                if overlapping && !graceExplicitlyCovered { grace.remaining = nil; grace.accuracy = .incomplete; grace.notes.append("Распределение между выписками требует подтверждения банка; один перевод не исполняет несколько требований автоматически.") }
                rows.append(grace)
            }
        }
        if terms.credit.grace == .transactionDays || terms.credit.grace == .cycleDays || terms.credit.grace == .promotion || terms.credit.grace == .manual {
            rows.removeAll { $0.kind == .gracePayment }
            for lot in try FinancialLedger.creditLots(accountID: contract.accountID, db: db, on: asOf) {
                guard terms.credit.buckets.first(where: { $0.kind == lot.kind })?.eligibleForGrace != false else { continue }
                let deadline: Day?
                switch terms.credit.grace { case .transactionDays: deadline = lot.date.adding(terms.credit.graceDays); case .cycleDays: deadline = lot.date.firstOfMonth.adding(terms.credit.graceDays); default: deadline = terms.credit.graceEnd }
                if let deadline {
                    var row = try event(contract: contract, kind: .gracePayment, date: deadline, anchor: lot.id.uuidString, components: [FinancialAllocation(.principal, lot.amount, lotID: lot.id)], amount: lot.amount, db: db)
                    // The lot is already the unpaid ledger remainder; fulfillment must not deduct the same payment twice.
                    row.remaining = lot.amount
                    rows.append(row)
                }
            }
        }
        return rows
    }
    public static func creditCost(contract: FinancialContract, db: Database, paymentDate: Day, asOf: Day = .today) throws -> CreditCostScenario {
        guard contract.kind == .revolvingCredit, paymentDate >= asOf, let currentTerms = contract.terms(on: asOf) else { throw BudgetError.invalid("Выберите кредитную карту и будущую дату зачисления.") }
        let points = try FinancialLedger.creditExposure(accountID: contract.accountID, db: db, through: asOf)
        var descriptions: [UUID: CreditLotBalance] = [:]
        for point in points { for lot in point.lots { descriptions[lot.id] = lot } }
        let statements = db.financeData.statements.filter { $0.contractID == contract.id }
        func amount(_ id: UUID, on date: Day) -> Int64 {
            var low = 0, high = points.count
            while low < high { let mid = (low + high) / 2; if points[mid].date <= date { low = mid + 1 } else { high = mid } }
            return low == 0 ? 0 : points[low - 1].lots.first { $0.id == id }?.amount ?? 0
        }
        var interest: Int64 = 0, late = false, notes: [String] = [], accuracy = ForecastAccuracy.calculated
        for lot in descriptions.values {
            try Task.checkCancellation()
            guard let initial = contract.terms(on: lot.date) else { return CreditCostScenario(interest: nil, fees: 0, total: nil, accuracy: .incomplete, notes: ["Неизвестны исторические условия транша."]) }
            let eligible = initial.credit.buckets.first(where: { $0.kind == lot.kind })?.eligibleForGrace != false && initial.credit.grace != .none
            var deadline: Day?
            if eligible {
                switch initial.credit.grace {
                case .transactionDays: deadline = lot.date.adding(initial.credit.graceDays)
                case .cycleDays: deadline = lot.date.firstOfMonth.adding(initial.credit.graceDays)
                case .promotion, .manual: deadline = initial.credit.graceEnd
                case .statement:
                    if let statement = statements.filter({ $0.start <= lot.date && lot.date <= $0.closedOn }).min(by: { $0.closedOn < $1.closedOn }) { deadline = statement.dueOn }
                    else { var closed = try FinanceMath.addingMonths(lot.date, 0, anchor: initial.credit.closingDay); if closed < lot.date { closed = try FinanceMath.addingMonths(closed, 1, anchor: initial.credit.closingDay) }; deadline = closed.adding(initial.credit.dueDays) }
                case .none: break
                }
                guard let due = deadline else { return CreditCostScenario(interest: nil, fees: 0, total: nil, accuracy: .incomplete, notes: ["Неизвестен льготный дедлайн транша."]) }
                if contract.cutoffHour != nil, db.operations.contains(where: { $0.kind == .transfer && $0.toAccountID == contract.accountID && $0.date == due && $0.date <= asOf && creditedOnTime($0, contract: contract, deadline: due) != true }) { return CreditCostScenario(interest: nil, fees: 0, total: nil, accuracy: .incomplete, notes: ["Платёж в день дедлайна требует времени зачисления и начисления банка после cut-off. Задайте сумму из выписки."]) }
                if paymentDate <= due || due <= asOf && amount(lot.id, on: due) == 0 { continue }
                late = true
            }
            var start = lot.date
            if eligible, let deadline { switch initial.credit.accrualAfterGrace { case .afterDeadline: start = deadline.adding(1); case .fromTransaction: start = lot.date; case .fromCycle: start = lot.date.firstOfMonth } }
            if paymentDate <= start { continue }
            var intervals = Set(points.map(\.date).filter { $0 > start && $0 < paymentDate }); intervals.formUnion(contract.terms.map(\.effectiveFrom).filter { $0 > start && $0 < paymentDate }); intervals.insert(start); intervals.insert(paymentDate)
            let boundaries = intervals.sorted(); var raw = Decimal(0)
            for index in 0..<(boundaries.count - 1) {
                let first = boundaries[index], last = boundaries[index + 1]
                guard var terms = contract.terms(on: first) else { return CreditCostScenario(interest: nil, fees: 0, total: nil, accuracy: .incomplete, notes: ["Нет условий периода начисления."]) }
                let balance = amount(lot.id, on: min(first, asOf))
                if balance == 0 { continue }
                terms.annualPercent = terms.credit.buckets.first(where: { $0.kind == lot.kind })?.annualPercent ?? terms.annualPercent
                guard let annual = try terms.rate(), terms.rateKind == .nominalAnnual, terms.basis != .equalMonths else { return CreditCostScenario(interest: nil, fees: 0, total: nil, accuracy: .incomplete, notes: ["Для этого вида ставки / периода задайте начисления банка вручную."]) }
                if terms.roundingPoint == .daily {
                    var day = first
                    while day < last { try Task.checkCancellation(); raw += Decimal(try FinanceMath.rounded(Decimal(balance) * annual * FinanceMath.fraction(day, day.adding(1), basis: terms.basis), mode: terms.rounding)); day = day.adding(1) }
                } else { raw += try Money.multiply(Decimal(balance), Money.multiply(annual, FinanceMath.fraction(first, last, basis: terms.basis))) }
                if terms.scenarioRate { accuracy = .scenario }
            }
            interest = try Money.add(interest, FinanceMath.rounded(raw, mode: initial.rounding))
        }
        if currentTerms.credit.carriedDebtLosesGrace || currentTerms.credit.penaltyAnnualPercent != nil { notes.append("Перенос долга / штрафная ставка требуют сверки по выписке; показаны базовые проценты."); accuracy = .incomplete }
        let alreadyCharged = try db.operations.filter { $0.accountID == contract.accountID && $0.kind == .expense && $0.financial?.component == .interest && $0.date <= asOf }.reduce(Int64(0)) { try Money.add($0, $1.amount) }
        interest = max(0, interest - alreadyCharged)
        let fee = late ? currentTerms.credit.lateFee : 0
        return CreditCostScenario(interest: interest, fees: fee, total: try Money.add(interest, fee), accuracy: accuracy, notes: notes + ["Без будущих покупок; подтверждённые процентные начисления вычтены из прогноза."])
    }
    private static func creditedOnTime(_ operation: Operation, contract: FinancialContract, deadline: Day) -> Bool? {
        if operation.date < deadline { return true }
        if operation.date > deadline { return false }
        guard let hour = contract.cutoffHour else { return true }
        guard let instant = operation.financial?.creditedAt, let zone = TimeZone(identifier: contract.timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: instant)
        let local = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        if local != deadline.rawValue { return local < deadline.rawValue }
        return (components.hour ?? 24) < hour
    }
    public static func prepayment(contract: FinancialContract, db: Database, amount: Int64, mode: PrepaymentMode, asOf: Day = .today) throws -> LoanScenario {
        guard contract.kind == .mortgage || contract.kind == .termLoan, let end = contract.end, let terms = contract.terms(on: asOf) else { throw BudgetError.invalid("Выберите срочный кредит / ипотеку.") }
        let principal = try FinancialLedger.debt(accountID: contract.accountID, db: db, on: asOf).amount(.principal)
        guard amount > 0, amount <= principal else { throw BudgetError.invalid("Досрочная сумма должна быть в пределах основного долга.") }
        let before = try loanEvents(contract: contract, db: db, asOf: asOf, horizon: end)
        let regular = before.first(where: { $0.date > asOf })?.components.filter { $0.component == .principal || $0.component == .interest }.reduce(Int64(0)) { $0 + $1.amount }
        var revised = contract; revised.end = before.last?.accrualEnd ?? end
        let after = try loanEvents(contract: revised, db: db, asOf: asOf, horizon: revised.end ?? end, scenarioPrincipal: principal - amount, reduceTermPayment: mode == .reduceTerm ? regular : nil, considerRecordedPrepayments: false, recalculatePaymentAfter: mode == .reducePayment ? asOf : nil).filter { $0.date > asOf }
        let fee = try terms.loan.prepaymentFeePercent.map { try FinanceMath.rounded(Decimal(max(0, amount - (terms.loan.freePrepaymentLimit ?? 0))) * Money.decimal($0) / 100) }
        let interest = after.contains(where: { $0.amount == nil }) ? nil : try after.reduce(Int64(0)) { try Money.add($0, $1.amount(.interest)) }
        return LoanScenario(events: after, remainingInterest: interest, fee: fee, end: after.last?.date, accuracy: mode == .manual || after.contains(where: { $0.accuracy != .calculated }) ? .incomplete : .calculated)
    }
    public static func depositExit(contract: FinancialContract, db: Database, exitOn: Day, asOf: Day = .today) throws -> DepositExitScenario {
        guard contract.kind == .deposit, exitOn > contract.start, contract.end.map({ exitOn <= $0 }) ?? true else { throw BudgetError.invalid("Проверьте дату закрытия депозита.") }
        let interestOperations = db.operations.filter { $0.accountID == contract.accountID && $0.date >= contract.start && $0.date <= min(exitOn, asOf) && $0.kind == .income && $0.financial?.component == .interest }
        let paid = try interestOperations.reduce(Int64(0)) { try Money.add($0, $1.amount) }
        let groups = Set(interestOperations.compactMap { $0.financial?.groupID })
        var body = db; body.operations.removeAll { $0.financial?.groupID.map(groups.contains) == true }
        let timeline = try FinanceBalanceTimeline(accountID: contract.accountID, db: body)
        let current = max(0, try db.balance(contract.accountID, on: min(exitOn, asOf)))
        guard let terms = contract.terms(on: exitOn) else { throw BudgetError.invalid("Нет условий депозита.") }
        guard let early = terms.deposit.earlyAnnualPercent else { return DepositExitScenario(principal: current, recomputedInterest: nil, previouslyPaidInterest: paid, interestAdjustment: nil, fee: terms.deposit.earlyFee, returnBeforeNewTax: nil, accuracy: .incomplete, notes: ["Неизвестна ставка / правило досрочного перерасчёта. Укажите фактическую разницу банка вручную."]) }
        var revised = contract
        for index in revised.terms.indices { revised.terms[index].annualPercent = early; revised.terms[index].indexName = ""; revised.terms[index].deposit.tiers = []; revised.terms[index].deposit.capitalize = false }
        let earned = try accrue(contract: revised, start: max(contract.start, (try db.account(contract.accountID)).openedOn), end: exitOn) { day, terms in max(0, timeline.balance(on: terms.balanceBasis == .openingDay ? day.adding(-1) : day)) }
        let adjustment: Int64? = earned.0.map { $0 - paid }
        let returned: Int64? = try adjustment.map { try Money.add(try Money.add(current, $0), -terms.deposit.earlyFee) }
        return DepositExitScenario(principal: current, recomputedInterest: earned.0, previouslyPaidInterest: paid, interestAdjustment: adjustment, fee: terms.deposit.earlyFee, returnBeforeNewTax: returned, accuracy: earned.1, notes: earned.2 + ["Перерасчёт с начала текущего срока без капитализации; налог / дополнительные удержания уточните по документу банка."])
    }

}
