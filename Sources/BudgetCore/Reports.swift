import Foundation

public struct Valuation: Equatable, Sendable {
    public var known: Int64 = 0; public var missing: [UUID] = []; public var currencies: Set<String> = []; public var count = 0
    public var missingConditions: [UUID] = []
    public var partial: Bool { !missing.isEmpty || !missingConditions.isEmpty }
    public var partialDescription: String { [missing.isEmpty ? nil : "без курса: \(missing.count)", missingConditions.isEmpty ? nil : "без условий: \(missingConditions.count)"].compactMap { $0 }.joined(separator: "; ") }
    public init() {}
    public func label(currency: String) -> String { Money.display(known, currency: currency) + (partial ? " · частично (\(partialDescription))" : "") }
}
public struct ReportRow: Identifiable, Equatable, Sendable {
    public var id: String; public var title: String; public var value: Valuation; public var operationIDs: [UUID] = []; public var accountIDs: [UUID] = []
    public init(id: String, title: String, value: Valuation = Valuation()) { self.id = id; self.title = title; self.value = value }
}
private struct BudgetMatcher {
    let kind: BudgetKind; let start: Day; let end: Day?; let projectID: UUID?; let categories: Set<UUID>
    init(_ budget: Budget, db: Database) {
        kind = budget.kind; start = budget.start; end = budget.endDate; projectID = budget.projectID
        let parents = Set(budget.lines.map(\.categoryID))
        categories = parents.union(db.categories.filter { $0.parentID.map(parents.contains) == true }.map(\.id))
    }
    func matches(_ o: Operation) -> Bool {
        o.kind == .expense && o.budgetMode == .automatic && o.date >= start && (end == nil || o.date <= end!) && (kind == .project ? o.projectID == projectID : o.categoryID.map(categories.contains) == true)
    }
}
public enum Reports {
    public static func rate(from: String, to: String, rates: [FXRate], on day: Day) throws -> String? {
        try resolvedRate(from: from, to: to, rates: rates, on: day)?.value
    }
    public static func resolvedRate(from: String, to: String, rates: [FXRate], on day: Day) throws -> ResolvedRate? {
        if from == to { return ResolvedRate(value: "1", date: nil, provider: nil) }
        let eligible = rates.filter { $0.date <= day }.sorted { $0.date == $1.date ? $0.fetchedAt > $1.fetchedAt : $0.date > $1.date }
        if let r = eligible.first(where: { $0.base == from && $0.quote == to }) { return ResolvedRate(value: r.rate, date: r.date, provider: r.provider) }
        if let r = eligible.first(where: { $0.base == to && $0.quote == from }) { return ResolvedRate(value: NSDecimalNumber(decimal: try Money.divide(1, Money.decimal(r.rate))).stringValue, date: r.date, provider: r.provider) }
        for a in eligible {
            if a.base == from, let b = eligible.first(where: { $0.base == to && $0.quote == a.quote && $0.date == a.date && $0.provider == a.provider }) {
                return ResolvedRate(value: NSDecimalNumber(decimal: try Money.divide(Money.decimal(a.rate), Money.decimal(b.rate))).stringValue, date: a.date, provider: a.provider)
            }
            let aTo: String; let aRate: Decimal
            if a.base == from { aTo = a.quote; aRate = try Money.decimal(a.rate) }
            else if a.quote == from { aTo = a.base; aRate = try Money.divide(1, Money.decimal(a.rate)) } else { continue }
            if let b = eligible.first(where: { $0.date == a.date && $0.provider == a.provider && (($0.base == aTo && $0.quote == to) || ($0.quote == aTo && $0.base == to)) }) {
                let br = try b.base == aTo ? Money.decimal(b.rate) : Money.divide(1, Money.decimal(b.rate))
                return ResolvedRate(value: NSDecimalNumber(decimal: try Money.multiply(aRate, br)).stringValue, date: a.date, provider: a.provider)
            }
        }
        return nil
    }
    public static func validateFilters(_ f: Filters, db: Database) throws {
        guard f.start == nil || f.end == nil || f.start! <= f.end!, f.accounts.isSubset(of: Set(db.accounts.map(\.id))), f.categories.isSubset(of: Set(db.categories.map(\.id))), f.projectID == nil || db.projects.contains(where: { $0.id == f.projectID }) else { throw BudgetError.invalid("Некорректный период или удалённый справочник в фильтре.") }
        if let c = f.currency { _ = try Currency.get(c) }
    }
    public static func validate(_ r: Report, db: Database) throws {
        try Ledger.nonempty(r.name); _ = try Currency.get(r.currency); try validateFilters(r.filters, db: db)
        if [.debt, .financialPlan, .depositYield].contains(r.dataset) {
            let allowed: [Metric] = r.dataset == .debt ? [.balance, .principal, .interest, .fees] : r.dataset == .financialPlan ? [.payment, .grace] : [.yield, .netYield]
            guard allowed.contains(r.metric), [.account, .day, .month].contains(r.grouping), r.filters.categories.isEmpty, r.filters.projectID == nil, r.filters.participation == .all else { throw BudgetError.invalid("Для финансового отчёта доступны счёт, день и месяц; категории, проекты и бюджеты не применяются.") }
            guard r.presentation != .ring || r.dataset == .debt else { throw BudgetError.invalid("Для прогнозов выберите таблицу, линию или столбцы.") }
        } else if r.dataset == .balances {
            guard r.metric == .balance, [.day, .month, .account].contains(r.grouping), r.filters.categories.isEmpty, r.filters.projectID == nil else { throw BudgetError.invalid("Для остатков доступны счёт, день и месяц; категория/проект не применяются.") }
        } else { guard [Metric.income, .expense, .net, .count].contains(r.metric) else { throw BudgetError.invalid("Остаток требует набор данных «Остатки».") } }
        guard r.presentation != .line || [.day, .month].contains(r.grouping) else { throw BudgetError.invalid("Линия требует группировку по времени.") }
        if r.presentation == .ring {
            guard r.metric != .net else { throw BudgetError.invalid("Кольцо не поддерживает разницу с отрицательными группами.") }
            if r.dataset == .balances { guard !(try rows(r, db: db, validating: false)).contains(where: { $0.value.known < 0 }) else { throw BudgetError.invalid("Кольцо не поддерживает отрицательные остатки.") } }
        }
    }
    public static func selected(_ db: Database, filters f: Filters, kinds: Set<OperationKind>? = nil, sorted: Bool = true) -> [Operation] {
        let accounts = Dictionary(uniqueKeysWithValues: db.accounts.map { ($0.id, $0) })
        let parents = Dictionary(uniqueKeysWithValues: db.categories.map { ($0.id, $0.parentID) })
        let matchers = f.participation == .all ? [] : db.budgets.map { BudgetMatcher($0, db: db) }
        let result = db.operations.filter { o in
            guard kinds == nil || kinds!.contains(o.kind), f.start == nil || o.date >= f.start!, f.end == nil || o.date <= f.end!, f.accounts.isEmpty || f.accounts.contains(o.accountID) || o.toAccountID.map(f.accounts.contains) == true,
                  f.categories.isEmpty || o.categoryID.map({ f.categories.contains($0) || (parents[$0] ?? nil).map(f.categories.contains) == true }) == true,
                  f.projectID == nil || f.projectID == o.projectID,
                  f.currency == nil || f.currency == accounts[o.accountID]?.currency,
                  f.includeArchived || accounts[o.accountID]?.archived == false,
                  f.search.isEmpty || o.comment.localizedCaseInsensitiveContains(f.search) else { return false }
            guard f.participation != .all else { return true }
            let matches = matchers.filter { $0.matches(o) }
            switch f.participation { case .all: return true; case .outside: return matches.isEmpty; case .noMonthly: return !matches.contains { $0.kind == .monthly }; case .noProject: return !matches.contains { $0.kind == .project } }
        }
        return sorted ? result.sorted { $0.date == $1.date ? (f.newestFirst ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt) : (f.newestFirst ? $0.date > $1.date : $0.date < $1.date) } : result
    }
    public static func sum(_ operations: [Operation], db: Database, currency: String, net: Bool = false) throws -> Valuation {
        let accounts = Dictionary(uniqueKeysWithValues: db.accounts.map { ($0.id, $0) }); var result = Valuation()
        for o in operations {
            guard let a = accounts[o.accountID] else { throw BudgetError.corrupt }; result.count += 1
            if let rate = try rate(from: a.currency, to: currency, rates: o.fx, on: o.date) {
                let amount = try Money.convert(o.amount, from: a.currency, to: currency, rate: rate)
                let signed = net && o.kind == .expense ? -amount : amount; result.known = try Money.add(result.known, signed)
            } else { result.missing.append(o.id); result.currencies.insert(a.currency) }
        }
        return result
    }
    public static func balances(_ db: Database, filters: Filters, currency: String, day: Day = .today) throws -> [ReportRow] {
        try accountBalances(db, filters: filters, currency: currency, day: day).map(\.reportRow)
    }
    public static func total(_ rows: [ReportRow]) throws -> Valuation { try rows.reduce(Valuation()) { v, row in var r = v; r.known = try Money.add(r.known, row.value.known); r.missing += row.value.missing; r.missingConditions += row.value.missingConditions; r.currencies.formUnion(row.value.currencies); r.count += row.value.count; return r } }
    public static func budgetFact(_ b: Budget, db: Database, lineID: UUID? = nil, filters: Filters? = nil) throws -> Valuation {
        let ops = filters.map { selected(db, filters: $0, kinds: [.expense], sorted: false) } ?? db.operations
        let line = b.lines.first { $0.id == lineID }
        let matcher = BudgetMatcher(b, db: db)
        let lineCategories = line.map { l in Set([l.categoryID] + db.categories.filter { $0.parentID == l.categoryID }.map(\.id)) }
        return try sum(ops.filter { matcher.matches($0) && (lineCategories == nil || $0.categoryID.map(lineCategories!.contains) == true) }, db: db, currency: b.currency)
    }
    public static func rows(_ r: Report, db: Database, validating: Bool = true) throws -> [ReportRow] {
        if validating { try validate(r, db: db) }
        if [.debt, .financialPlan, .depositYield].contains(r.dataset) { return try FinancialReports.rows(r, db: db) }
        if r.dataset == .balances {
            if r.grouping == .account { return try balances(db, filters: r.filters, currency: r.currency) }
            let start = r.filters.start ?? Day.today.firstOfMonth; let end = min(r.filters.end ?? .today, .today)
            var day = start; var result: [ReportRow] = []; var points = 0
            while day <= end {
                let point = r.grouping == .month ? min(day.lastOfMonth, end) : day
                var row = ReportRow(id: r.grouping == .month ? day.month : day.rawValue, title: r.grouping == .month ? day.month : day.rawValue, value: try total(balances(db, filters: r.filters, currency: r.currency, day: point)))
                row.accountIDs = db.accounts.filter { r.filters.accounts.isEmpty || r.filters.accounts.contains($0.id) }.map(\.id); result.append(row); day = point.adding(1); points += 1
                guard points <= 36600 else { throw BudgetError.invalid("Сократите период отчёта.") }
            }
            return result
        }
        let kinds: Set<OperationKind> = r.metric == .income ? [.income] : r.metric == .expense ? [.expense] : [.income, .expense]
        let ops = selected(db, filters: r.filters, kinds: kinds, sorted: false)
        let accounts = Dictionary(uniqueKeysWithValues: db.accounts.map { ($0.id, $0) }); let categories = Dictionary(uniqueKeysWithValues: db.categories.map { ($0.id, $0) }); let projects = Dictionary(uniqueKeysWithValues: db.projects.map { ($0.id, $0) })
        var groups: [String: [Operation]] = [:]; var titles: [String: String] = [:]
        for o in ops {
            let key: String; let title: String
            switch r.grouping {
            case .day: key = o.date.rawValue; title = key
            case .month: key = o.date.month; title = key
            case .account: key = o.accountID.uuidString; title = accounts[o.accountID]?.name ?? "—"
            case .category: let c = o.categoryID.flatMap { categories[$0] }; let id = c?.parentID ?? c?.id; key = id?.uuidString ?? "none"; title = id.flatMap { categories[$0]?.name } ?? "Без категории"
            case .subcategory: key = o.categoryID?.uuidString ?? "none"; title = db.categoryPath(o.categoryID)
            case .project: key = o.projectID?.uuidString ?? "none"; title = o.projectID.flatMap { projects[$0]?.name } ?? "Без проекта"
            }
            groups[key, default: []].append(o); titles[key] = title
        }
        let result = try groups.map { key, ops -> ReportRow in
            var v = Valuation(); if r.metric == .count { v.known = Int64(ops.count); v.count = ops.count } else { v = try sum(ops, db: db, currency: r.currency, net: r.metric == .net) }
            var row = ReportRow(id: key, title: titles[key]!, value: v); row.operationIDs = ops.map(\.id); return row
        }.sorted { [.day, .month].contains(r.grouping) ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if r.presentation == .ring, result.contains(where: { $0.value.known < 0 }) { throw BudgetError.invalid("Кольцо не поддерживает отрицательные группы. Выберите таблицу или столбцы.") }
        return result
    }
}
