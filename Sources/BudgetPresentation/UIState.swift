import Foundation
import BudgetCore

public enum PeriodPreset: String, CaseIterable, Sendable {
    case month, previous, all
    public var title: String { switch self { case .month: "Этот месяц"; case .previous: "Прошлый месяц"; case .all: "Всё время" } }
}

public struct DateRangeDraft: Equatable, Sendable {
    public var start: Day?
    public var end: Day?
    public private(set) var choosingEnd = false
    public init(start: Day?, end: Day?) { self.start = start; self.end = end }
    public mutating func select(_ day: Day) {
        if choosingEnd, let first = start { start = min(first, day); end = max(first, day); choosingEnd = false }
        else { start = day; end = nil; choosingEnd = true }
    }
    public mutating func preset(_ preset: PeriodPreset, today: Day) {
        choosingEnd = false
        switch preset {
        case .month: start = today.firstOfMonth; end = today
        case .previous: end = today.firstOfMonth.adding(-1); start = end?.firstOfMonth
        case .all: start = nil; end = nil
        }
    }
    public func apply(to filters: Filters) throws -> Filters {
        guard !choosingEnd, (start == nil && end == nil) || (start != nil && end != nil && start! <= end!) else { throw BudgetError.invalid("Выберите начало и конец периода.") }
        var value = filters; value.start = start; value.end = end; return value
    }
}

public enum CalendarDays {
    public static func month(_ day: Day, offset: Int) -> Day {
        Day.utc(Day.calendar.date(byAdding: .month, value: offset, to: day.firstOfMonth.date)!)
    }
    public static func cells(_ month: Day) -> [Day?] {
        let first = month.firstOfMonth
        let leading = (Day.calendar.component(.weekday, from: first.date) + 5) % 7
        let count = Day.calendar.component(.day, from: first.lastOfMonth.date)
        return (0..<42).map { index in index >= leading && index < leading + count ? first.adding(index - leading) : nil }
    }
    // DatePicker uses local components. UTC midnight is not a local calendar day.
    public static func localDate(_ day: Day, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let parts = Day.calendar.dateComponents([.year, .month, .day], from: day.date)
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12))!
    }
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> Day {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return try! Day(String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!))
    }
    public static func label(_ day: Day, full: Bool = false) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.timeZone = Day.calendar.timeZone
        formatter.dateFormat = full ? "d MMMM yyyy" : "d MMM yyyy"; return formatter.string(from: day.date)
    }
    public static func range(_ filters: Filters, today: Day = .today) -> String {
        if filters.start == nil && filters.end == nil { return "Всё время" }
        if filters.start == today.firstOfMonth && filters.end == today { return "Этот месяц" }
        let previous = today.firstOfMonth.adding(-1)
        if filters.start == previous.firstOfMonth && filters.end == previous { return "Прошлый месяц" }
        if let a = filters.start, let b = filters.end { return a == b ? label(a) : label(a) + " — " + label(b) }
        return filters.start.map { "С " + label($0) } ?? filters.end.map { "По " + label($0) } ?? "Всё время"
    }
}

public struct FilterDraft: Equatable, Sendable {
    public private(set) var original: Filters
    public var value: Filters
    public init(_ filters: Filters) { original = filters; value = filters }
    public mutating func reset(today: Day, fixedAccount: UUID? = nil, period: Filters? = nil) {
        let order = value.newestFirst
        value = period.map { Filters(start: $0.start, end: $0.end) } ?? Filters(start: today.firstOfMonth, end: today); value.newestFirst = order
        if let fixedAccount { value.accounts = [fixedAccount] }
    }
    public func apply(database: Database, fixedAccount: UUID? = nil) throws -> Filters {
        var next = value; if let fixedAccount { next.accounts = [fixedAccount] }
        try Reports.validateFilters(next, db: database); return next
    }
    public var activeCount: Int { (value.accounts.isEmpty ? 0 : 1) + (value.categories.isEmpty ? 0 : 1) + (value.projectID == nil ? 0 : 1) + (value.currency == nil ? 0 : 1) + (value.participation == .all ? 0 : 1) + (value.includeArchived ? 0 : 1) }
}

public enum EditorContext {
    public static func account(in db: Database, kind: OperationKind, context: UUID? = nil) -> UUID? {
        let active = Set(db.accounts.filter { !$0.archived }.map(\.id))
        if let context, active.contains(context) { return context }
        if let used = db.operations.filter({ $0.kind == kind && active.contains($0.accountID) }).max(by: { $0.modifiedAt < $1.modifiedAt }) { return used.accountID }
        return active.count == 1 ? active.first : nil
    }
    public static func changingDataset(_ report: Report, to dataset: Dataset, database: Database? = nil) -> (Report, [String]) {
        var candidate = report; candidate.dataset = dataset; var removed: [String] = []
        if dataset != .flows {
            if !report.filters.categories.isEmpty { removed.append("Категории") }
            if report.filters.projectID != nil { removed.append("Проект") }
            if report.filters.participation != .all { removed.append("Участие в бюджетах") }
            candidate.filters.categories = []; candidate.filters.projectID = nil; candidate.filters.participation = .all
            candidate.metric = dataset == .financialPlan ? .payment : dataset == .depositYield ? .yield : .balance
            if ![Grouping.day, .month, .account].contains(candidate.grouping) { removed.append("Группировка"); candidate.grouping = .account }
        } else { candidate.metric = .expense }
        if candidate.presentation == .line && ![Grouping.day, .month].contains(candidate.grouping) { candidate.presentation = .table }
        if candidate.presentation == .ring, let database {
            var probe = candidate; probe.presentation = .table
            if let rows = try? Reports.rows(probe, db: database), rows.contains(where: { $0.value.known < 0 }) { candidate.presentation = .table; removed.append("Кольцевая диаграмма") }
        }
        return (candidate, removed)
    }
}

public struct OperationTableEntry: Identifiable, Sendable {
    public var operation: BudgetCore.Operation
    public var id: UUID { operation.id }
    public var date: Day { operation.date }
    public var kindTitle: String { operation.kind.title }
    public var comment: String { operation.comment }
    public var accountName: String
    public var amount: Int64
    public var currency: String
    public init(operation: BudgetCore.Operation, source: Account?, context: Account? = nil) {
        self.operation = operation; accountName = source?.name ?? "—"
        amount = context.map { operation.posting(for: $0.id) } ?? operation.amount
        currency = (context ?? source)?.currency ?? "RUB"
    }
}
