import Foundation
import BudgetCore

public enum WorkspaceSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case overview, plan, projects, accounts, operations
    public var id: String { rawValue }
    public var title: String { switch self { case .overview: "Обзор"; case .plan: "План"; case .projects: "Проекты"; case .accounts: "Счета"; case .operations: "Операции" } }
    public var icon: String { switch self { case .overview: "square.grid.2x2"; case .plan: "chart.xyaxis.line"; case .projects: "flag"; case .accounts: "wallet.bifold"; case .operations: "list.bullet.rectangle" } }
}
public enum PlanPage: String, CaseIterable, Codable, Identifiable, Sendable {
    case calendar, regular, goals, scenarios, taxes
    public var id: String { rawValue }
    public var title: String { switch self { case .calendar: "Движение денег"; case .regular: "Регулярный план"; case .goals: "Накопления"; case .scenarios: "Сценарии"; case .taxes: "Налоги" } }
}
public enum OperationsPage: String, CaseIterable, Codable, Identifiable, Sendable {
    case journal, budgets, reports, references
    public var id: String { rawValue }
    public var title: String { switch self { case .journal: "Журнал"; case .budgets: "Бюджеты"; case .reports: "Отчёты"; case .references: "Справочники" } }
}
public enum ProjectPage: String, CaseIterable, Codable, Identifiable, Sendable {
    case overview, costs, participants, payments, history
    public var id: String { rawValue }
    public var title: String { switch self { case .overview: "Обзор"; case .costs: "План и смета"; case .participants: "Участники"; case .payments: "Факт и платежи"; case .history: "История" } }
}
public enum JournalSelection: String, CaseIterable, Codable, Identifiable, Sendable {
    case all, expenses, incomes, transfers, adjustments, opening
    public var id: String { rawValue }
    public var title: String { switch self { case .all: "Все"; case .expenses: "Расходы"; case .incomes: "Доходы"; case .transfers: "Переводы"; case .adjustments: "Корректировки"; case .opening: "Начальные остатки" } }
    public var kind: OperationKind? { switch self { case .all: nil; case .expenses: .expense; case .incomes: .income; case .transfers: .transfer; case .adjustments: .adjustment; case .opening: .opening } }
}
public enum CalendarScope: String, CaseIterable, Codable, Identifiable, Sendable {
    case all, contracts, scheduled
    public var id: String { rawValue }
    public var title: String { switch self { case .all: "Весь денежный план"; case .contracts: "Договоры и рассрочки"; case .scheduled: "Запланированные расходы" } }
}
public struct WorkspaceRoute: Hashable, Codable, Sendable {
    public var section: WorkspaceSection
    public var planPage: PlanPage
    public var operationsPage: OperationsPage
    public var projectPage: ProjectPage
    public var calendarScope: CalendarScope
    public var objectID: UUID?
    public init(_ section: WorkspaceSection, plan: PlanPage = .calendar, operations: OperationsPage = .journal, project: ProjectPage = .overview, calendar: CalendarScope = .all, objectID: UUID? = nil) {
        self.section = section; planPage = plan; operationsPage = operations; projectPage = project; calendarScope = calendar; self.objectID = objectID
    }
}
public struct WorkspaceContext: Equatable, Sendable {
    public var search = ""
    public var archived = false
    public var filters = Filters()
    public var selectedID: UUID?
    public var scrollOffset: Double = 0
    public var tableScrollOffset: Double = 0
    public var tableScrollX: Double = 0
    public var journal = JournalSelection.all
    public var referencePage = 0
    public var budgetKind = BudgetKind.monthly
    public var calendarConditional = false
    public var accountKind: AccountKind?
    public var scheduledStatus = "Предстоящие"
    public var scheduledFrom = ""
    public var scheduledThrough = ""
    public var financialScope = 0
    public var includeFulfilled = false
    public var bankID: String?
    public var financialFrom = ""
    public var financialThrough = ""
    public init() {}
}
/// Session-only navigation. No financial mutation or unencrypted persistence.
public struct NavigationState: Equatable, Sendable {
    public private(set) var current = WorkspaceRoute(.overview)
    public private(set) var history: [WorkspaceRoute] = []
    public private(set) var contexts: [WorkspaceRoute: WorkspaceContext] = [:]
    public init() {}
    public var canGoBack: Bool { !history.isEmpty }
    public func context(for route: WorkspaceRoute) -> WorkspaceContext { contexts[route] ?? WorkspaceContext() }
    public mutating func updateContext(for route: WorkspaceRoute, _ update: (inout WorkspaceContext) -> Void) {
        var value = context(for: route); update(&value); contexts[route] = value
    }
    public mutating func go(to route: WorkspaceRoute) {
        guard route != current else { return }
        history.append(current)
        if history.count > 100 { history.removeFirst(history.count - 100) }
        current = route
    }
    public mutating func back() { if let previous = history.popLast() { current = previous } }
    public mutating func clear() { self = NavigationState() }
}
