import Foundation

public enum OperationKind: String, Codable, CaseIterable, Sendable {
    case expense, income, transfer, adjustment, opening
    public var title: String { switch self { case .expense: "Расход"; case .income: "Доход"; case .transfer: "Перевод"; case .adjustment: "Корректировка"; case .opening: "Начальный остаток" } }
    public var isFlow: Bool { self == .expense || self == .income }
}
public enum BudgetMode: String, Codable, CaseIterable, Sendable { case automatic, excluded
    public var title: String { self == .automatic ? "Автоматически" : "Вне бюджетов" }
}
public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var financialKind: AccountKind?; public var bankID: String?; public var contractID: UUID?
    public var kind: AccountKind { financialKind ?? .ordinary }
    public var id = UUID(); public var name: String; public var currency: String; public var openedOn: Day; public var archived = false; public var createdAt = Date(); public var modifiedAt = Date()
    public init(name: String, currency: String, openedOn: Day = .today) { self.name = name; self.currency = currency; self.openedOn = openedOn }
}
public struct Category: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID(); public var name: String; public var kind: OperationKind; public var parentID: UUID?; public var archived = false; public var system = false
    public init(name: String, kind: OperationKind, parentID: UUID? = nil, system: Bool = false) { self.name = name; self.kind = kind; self.parentID = parentID; self.system = system }
}
public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID(); public var name: String; public var description: String = ""; public var archived = false
    public init(name: String, description: String = "") { self.name = name; self.description = description }
}
public struct FXRate: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID(); public var base: String; public var quote: String; public var rate: String; public var date: Day; public var provider: String; public var fetchedAt = Date(); public var revision = 0
    public init(base: String, quote: String, rate: String, date: Day, provider: String = "Ручной") { self.base = base; self.quote = quote; self.rate = rate; self.date = date; self.provider = provider }
    public var label: String { "1 \(base) = \(rate) \(quote) · \(provider) · \(date)" }
    public var stale: Bool { date < Day.today.adding(-7) }
}
public struct Operation: Codable, Identifiable, Equatable, Sendable {
    public var financial: FinanceOperationDetails?
    public var id = UUID(); public var kind: OperationKind; public var date: Day; public var accountID: UUID; public var amount: Int64; public var toAccountID: UUID?; public var toAmount: Int64?; public var categoryID: UUID?; public var projectID: UUID?; public var comment = ""; public var budgetMode = BudgetMode.automatic; public var transferRate: String?; public var fx: [FXRate] = []; public var observedBalance: Int64?; public var createdAt = Date(); public var modifiedAt = Date()
    public init(kind: OperationKind, date: Day = .today, accountID: UUID, amount: Int64) { self.kind = kind; self.date = date; self.accountID = accountID; self.amount = amount }
    public func posting(for id: UUID) -> Int64 {
        if accountID == id { return kind == .expense || kind == .transfer ? -amount : amount }
        if kind == .transfer, toAccountID == id { return toAmount ?? 0 }; return 0
    }
}
public enum BudgetKind: String, Codable, CaseIterable, Sendable { case monthly, project
    public var title: String { self == .monthly ? "Месячный" : "Проектный" }
}
public struct BudgetLine: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID(); public var categoryID: UUID; public var limit: Int64
    public init(categoryID: UUID, limit: Int64) { self.categoryID = categoryID; self.limit = limit }
}
public struct Budget: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID(); public var kind: BudgetKind; public var name: String; public var currency: String; public var start: Day; public var end: Day?; public var projectID: UUID?; public var limit: Int64 = 0; public var lines: [BudgetLine] = []; public var completed = false
    public init(kind: BudgetKind, name: String, currency: String, start: Day) { self.kind = kind; self.name = name; self.currency = currency; self.start = start }
    public var endDate: Day? { kind == .monthly ? start.lastOfMonth : end }
    public var plan: Int64 { get throws { try kind == .monthly ? lines.reduce(0) { try Money.add($0, $1.limit) } : limit } }
}
public enum Participation: String, Codable, CaseIterable, Sendable { case all, outside, noMonthly, noProject }
public struct Filters: Codable, Equatable, Sendable {
    public var start: Day?; public var end: Day?; public var accounts: Set<UUID> = []; public var categories: Set<UUID> = []; public var projectID: UUID?; public var currency: String?; public var participation = Participation.all; public var search = ""; public var includeArchived = true; public var newestFirst = true
    public init(start: Day? = nil, end: Day? = nil) { self.start = start; self.end = end }
    public static var month: Filters { Filters(start: Day.today.firstOfMonth, end: .today) }
}
public enum Dataset: String, Codable, CaseIterable, Sendable { case flows, balances, debt, financialPlan, depositYield }
public enum Metric: String, Codable, CaseIterable, Sendable { case income, expense, net, count, balance, principal, interest, fees, payment, grace, yield, netYield }
public enum Grouping: String, Codable, CaseIterable, Sendable { case day, month, account, category, subcategory, project }
public enum Presentation: String, Codable, CaseIterable, Sendable { case table, bars, line, ring }
public struct Report: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID(); public var name: String; public var dataset = Dataset.flows; public var metric = Metric.expense; public var grouping = Grouping.category; public var filters = Filters.month; public var currency = "RUB"; public var presentation = Presentation.table
    public init(name: String) { self.name = name }
}
public struct DashboardBlock: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID(); public var kind: String; public var reportID: UUID?; public var visible = true; public var wide = false; public var ownFilters: Filters?
    public init(kind: String, reportID: UUID? = nil) { self.kind = kind; self.reportID = reportID }
    public static var defaults: [DashboardBlock] { ["balances", "flows", "trend", "categories", "monthly", "projects", "outside"].map { var b = DashboardBlock(kind: $0); b.wide = false; return b } }
}
public struct ImportBatch: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID(); public var date = Date(); public var fingerprint: String; public var added: [UUID]; public var skipped: Int; public var excluded: Int
    public init(fingerprint: String, added: [UUID], skipped: Int, excluded: Int) { self.fingerprint = fingerprint; self.added = added; self.skipped = skipped; self.excluded = excluded }
}
public struct AppSettings: Codable, Equatable, Sendable {
    public var baseCurrency = "RUB"; public var reportCurrency = "RUB"; public var lockMinutes = 5; public var dashboardFilters = Filters.month; public var backupPath: String?; public var backupBookmark: Data?; public var lastBackup: Date?; public var lastDaily: Day?; public var lastRateCheck: Date?
    public init() {}
}
public struct Database: Codable, Equatable, Sendable {
    /// Optional for decoding version-1 files written before revision tracking was introduced.
    public var revision: UInt64? = 0
    public var finances: FinancialBook?
    public var version = 3; public var id = UUID(); public var accounts: [Account] = []; public var categories: [Category] = [Category(name: "Без категории", kind: .expense, system: true), Category(name: "Без категории", kind: .income, system: true)]; public var projects: [Project] = []; public var operations: [Operation] = []; public var budgets: [Budget] = []; public var rates: [FXRate] = []; public var reports: [Report] = []; public var dashboard = DashboardBlock.defaults; public var imports: [ImportBatch] = []; public var settings = AppSettings()
    public init() {}
    public func account(_ id: UUID) throws -> Account { guard let a = accounts.first(where: { $0.id == id }) else { throw BudgetError.missing("Счёт не найден.") }; return a }
    public func categoryPath(_ id: UUID?) -> String { guard let c = categories.first(where: { $0.id == id }) else { return "—" }; if let p = categories.first(where: { $0.id == c.parentID }) { return p.name + " / " + c.name }; return c.name }
    public func balance(_ id: UUID, on day: Day = .today) throws -> Int64 { try operations.lazy.filter { $0.date <= day && ($0.accountID == id || $0.toAccountID == id) }.reduce(0) { try Money.add($0, $1.posting(for: id)) } }
}
