import Foundation

public enum PlanFrequency: String, Codable, CaseIterable, Sendable {
    case once, weekly, monthly, yearly, manual
    public var title: String { switch self { case .once: "Разово"; case .weekly: "Каждую неделю"; case .monthly: "Каждый месяц"; case .yearly: "Каждый год"; case .manual: "Свои даты" } }
}
public enum PlanPurpose: String, Codable, CaseIterable, Sendable {
    case payment, living, income
    public var title: String { switch self { case .payment: "Обязательный платёж"; case .living: "Лимит жизни"; case .income: "Поступление" } }
}
public enum PlanCertainty: String, Codable, CaseIterable, Sendable {
    case committed, estimated, conditional
    public var title: String { switch self { case .committed: "Подтверждённый план"; case .estimated: "Оценка"; case .conditional: "Условно" } }
}
public struct PlanException: Codable, Equatable, Sendable {
    public var anchor: Day; public var date: Day?; public var amount: Int64?; public var cancelled = false; public var closed = false
    public init(anchor: Day) { self.anchor = anchor }
}
public struct PlanFlowVersion: Codable, Equatable, Sendable {
    public var validUntil: Day; public var snapshot: Data
    public init(validUntil: Day, snapshot: Data) { self.validUntil = validUntil; self.snapshot = snapshot }
}
public struct PlanFlow: Codable, Equatable, Identifiable, Sendable {
    public var parentFlowID: UUID?
    public var history: [PlanFlowVersion]?

    public var id = UUID(); public var title: String; public var purpose: PlanPurpose; public var amount: Int64?; public var currency: String; public var start: Day
    public var end: Day?; public var frequency = PlanFrequency.monthly; public var dates: [Day] = []; public var exceptions: [PlanException] = []
    public var accountID: UUID?; public var categoryID: UUID?; public var projectID: UUID?; public var participantID: UUID?
    public var personalImpact: Bool?
    public var certainty = PlanCertainty.committed; public var enabled = true; public var comment = ""; public var scheduledPaymentID: UUID?; public var financeEventID: String?
    public init(title: String, purpose: PlanPurpose, amount: Int64?, currency: String, start: Day) { self.title = title; self.purpose = purpose; self.amount = amount; self.currency = currency; self.start = start }
}
public struct PlanAllocation: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var occurrenceID: String; public var operationID: UUID; public var sourceAmount: Int64; public var amount: Int64
    public init(occurrenceID: String, operationID: UUID, sourceAmount: Int64, amount: Int64) { self.occurrenceID = occurrenceID; self.operationID = operationID; self.sourceAmount = sourceAmount; self.amount = amount }
}
public struct SavingsGoal: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var title: String; public var target: Int64; public var currency: String; public var dueOn: Day
    public var allocated: Int64 = 0; public var monthly: Int64 = 0; public var accountID: UUID?; public var projectID: UUID?
    public init(title: String, target: Int64, currency: String, dueOn: Day) { self.title = title; self.target = target; self.currency = currency; self.dueOn = dueOn }
}
public struct PlanScenario: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var title: String; public var snapshotRevision: UInt64; public var flows: [PlanFlow]; public var reserve: Int64; public var currency: String
    public var projectDelayDays: Int?; public var goalMonthlyPercent: Int?
    public init(title: String, snapshotRevision: UInt64, flows: [PlanFlow], reserve: Int64, currency: String) { self.title = title; self.snapshotRevision = snapshotRevision; self.flows = flows; self.reserve = reserve; self.currency = currency }
}
public enum ProjectType: String, Codable, CaseIterable, Sendable {
    case other, mortgage, renovation, construction, business
    public var title: String { switch self { case .other: "Другая цель"; case .mortgage: "Ипотека / кредит"; case .renovation: "Ремонт"; case .construction: "Строительство"; case .business: "Бизнес" } }
    public var icon: String { switch self { case .other: "flag"; case .mortgage: "house"; case .renovation: "paintbrush"; case .construction: "hammer"; case .business: "storefront" } }
}
public enum ProjectStage: String, Codable, CaseIterable, Sendable {
    case idea, planning, active, completed, cancelled
    public var title: String { switch self { case .idea: "Идея"; case .planning: "Планирование"; case .active: "В работе"; case .completed: "Завершён"; case .cancelled: "Отменён" } }
}
public struct ProjectParticipant: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var name: String; public var role = "Участник"; public var isUser = false
    public var ownershipPercent: String?; public var incomePercent: String?; public var promised: Int64 = 0; public var confirmed = false
    public init(name: String) { self.name = name }
}
public struct ProjectCost: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var title: String; public var stage = ""; public var amount: Int64; public var dueOn: Day; public var contracted = false
    public var participantID: UUID?; public var scheduledPaymentID: UUID?; public var flowID: UUID?; public var accepted = false; public var contractor = ""; public var quantity: String?; public var unitPrice: Int64?
    public init(title: String, amount: Int64, dueOn: Day) { self.title = title; self.amount = amount; self.dueOn = dueOn }
}
public enum ProjectFactKind: String, Codable, CaseIterable, Sendable {
    case expense, revenue, contribution, distribution, reimbursement
    public var title: String { switch self { case .expense: "Затрата проекта"; case .revenue: "Выручка проекта"; case .contribution: "Вклад / финансирование"; case .distribution: "Доход участника"; case .reimbursement: "Возмещение участнику" } }
}
public struct ProjectFact: Codable, Equatable, Identifiable, Sendable {
    public var kind: ProjectFactKind?
    public var effectiveKind: ProjectFactKind { kind ?? (income ? .revenue : .expense) }

    public var id = UUID(); public var costID: UUID?; public var participantID: UUID?; public var operationID: UUID?; public var date: Day; public var amount: Int64
    public var income = false; public var source = "Введено вручную"; public var confirmed = false; public var reimbursementPaymentID: UUID?
    public init(date: Day, amount: Int64) { self.date = date; self.amount = amount }
}
public struct ProjectPlanVersion: Codable, Equatable, Identifiable, Sendable {
    public var loan: ProjectLoan?; public var business: BusinessModel?; public var target: Int64; public var dueOn: Day?
    public var id = UUID(); public var date = Date(); public var reason: String; public var costs: [ProjectCost]; public var reserve: Int64; public var participants: [ProjectParticipant]
    public init(reason: String, details: ProjectDetails) { loan = details.loan; business = details.business; target = details.target; dueOn = details.dueOn; self.reason = reason; costs = details.costs; reserve = details.reserve; participants = details.participants }
}
public struct BusinessModel: Codable, Equatable, Sendable {
    public var horizonMonths: Int?
    public var initial: Int64 = 0; public var revenue: Int64 = 0; public var fixed: Int64 = 0; public var variable: Int64 = 0; public var tax: Int64 = 0; public var currency = "RUB"; public var taxBasis = "Ручной план"
    public init() {}
}
public struct ProjectPrepayment: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var date: Day; public var amount: Int64; public var mode: PrepaymentMode
    public init(date: Day, amount: Int64, mode: PrepaymentMode) { self.date = date; self.amount = amount; self.mode = mode }
}
public struct ProjectLoanRate: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var date: Day; public var annualPercent: String
    public init(date: Day, annualPercent: String) { self.date = date; self.annualPercent = annualPercent }
}
public struct ProjectLoan: Codable, Equatable, Sendable {
    public var rateChanges: [ProjectLoanRate]?

    public var principal: Int64 = 0; public var downPayment: Int64 = 0; public var annualPercent = "0"; public var months = 120; public var firstPayment = Day.today.adding(30)
    public var differentiated = false; public var prepayments: [ProjectPrepayment] = []; public var contractID: UUID?; public var note = "Модель: ставка / 12, без неизвестных комиссий"; public var manual: [ProjectLoanRow] = []
    public init() {}
}
public struct ProjectLoanRow: Codable, Equatable, Identifiable, Sendable {
    public var id: String { date.rawValue }; public var date: Day; public var principal: Int64; public var interest: Int64; public var extra: Int64; public var remaining: Int64
    public var payment: Int64 { get throws { try Money.add(try Money.add(principal, interest), extra) } }
    public init(date: Day, principal: Int64, interest: Int64, extra: Int64 = 0, remaining: Int64) { self.date = date; self.principal = principal; self.interest = interest; self.extra = extra; self.remaining = remaining }
}
public struct ProjectDetails: Codable, Equatable, Sendable {
    public var type = ProjectType.other; public var stage = ProjectStage.idea; public var currency = "RUB"; public var target: Int64 = 0; public var dueOn: Day?
    public var costs: [ProjectCost] = []; public var participants: [ProjectParticipant] = []; public var facts: [ProjectFact] = []; public var reserve: Int64 = 0
    public var versions: [ProjectPlanVersion] = []; public var loan: ProjectLoan?; public var business: BusinessModel?; public var migrated = false
    public init() {}
}
public struct PlanningEventSettings: Codable, Equatable, Sendable {
    public var enabledTypes: [String] = ["payment", "deposit", "deficit", "project", "tax"]
    public var paymentDays = 7; public var depositDays = 14; public var deficitDays = 30
    public var priorityOverrides: [String:Int]?
    public var hiddenKeys: [String] = []; public var snoozed: [String: Day] = [:]; public var sourceExclusions: [String] = []
    public init() {}
}
public struct PlanningAudit: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var date = Date(); public var actor: UUID; public var action: String; public var entityID: UUID; public var revision: UInt64; public var reason: String
    public init(actor: UUID, action: String, entityID: UUID, revision: UInt64, reason: String) { self.actor = actor; self.action = action; self.entityID = entityID; self.revision = revision; self.reason = reason }
}
public struct PlanningReceipt: Codable, Equatable, Sendable {
    public var requestID: UUID; public var fingerprint: String; public var resultID: UUID
}
public struct PlanningBook: Codable, Equatable, Sendable {
    public var allocationRules: [IncomeAllocationRule] = []; public var distributionIncome: Int64 = 0
    public var flows: [PlanFlow] = []; public var allocations: [PlanAllocation] = []; public var goals: [SavingsGoal] = []; public var scenarios: [PlanScenario] = []
    public var reserve: Int64 = 0; public var reserveCurrency = "RUB"; public var forecastRates: [FXRate] = []
    public var eventSettings = PlanningEventSettings(); public var taxes: [TaxProfile] = []; public var taxResults: [TaxCalculation] = []
    public var audit: [PlanningAudit] = []; public var receipts: [PlanningReceipt] = []; public var accountCards = false; public var accountSort = "name"
    public init() {}
}
extension Database {
    public var planningData: PlanningBook { get { planning ?? PlanningBook() } set { planning = newValue } }
}
