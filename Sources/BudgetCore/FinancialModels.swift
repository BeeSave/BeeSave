import Foundation

public enum AccountKind: String, Codable, CaseIterable, Sendable {
    case ordinary, deposit, revolvingCredit, termLoan, mortgage
    public var title: String {
        switch self { case .ordinary: return "Обычный"; case .deposit: return "Депозит"; case .revolvingCredit: return "Кредитная карта / линия"; case .termLoan: return "Кредит"; case .mortgage: return "Ипотека" }
    }
    public var isDebt: Bool { self == .revolvingCredit || self == .termLoan || self == .mortgage }
    public var icon: String { switch self { case .ordinary: return "wallet.bifold"; case .deposit: return "percent"; case .revolvingCredit: return "creditcard"; case .termLoan: return "banknote"; case .mortgage: return "house" } }
}
public enum FinancialMarket: String, Codable, CaseIterable, Sendable {
    case ru = "RU", us = "US", gb = "GB", other = "OTHER"
    public var title: String { switch self { case .ru: return "Россия"; case .us: return "США"; case .gb: return "Великобритания"; case .other: return "Свои условия" } }
}
public enum ContractStatus: String, Codable, CaseIterable, Sendable {
    case draft, active, closed
    public var title: String { switch self { case .draft: return "Черновик"; case .active: return "Действует"; case .closed: return "Закрыт" } }
}
public enum InterestBasis: String, Codable, CaseIterable, Sendable {
    case actual365, actualActual, actual360, thirtyE360, thirtyUS360, equalMonths
    public var title: String { switch self { case .actual365: return "Actual/365 Fixed"; case .actualActual: return "Actual/Actual"; case .actual360: return "Actual/360"; case .thirtyE360: return "30E/360"; case .thirtyUS360: return "30/360 US"; case .equalMonths: return "Равные месяцы · ставка / 12" } }
}
public enum RateKind: String, Codable, CaseIterable, Sendable { case nominalAnnual, effectiveAnnual, periodic
    public var title: String { switch self { case .nominalAnnual: return "Номинальная годовая"; case .effectiveAnnual: return "Эффективная годовая"; case .periodic: return "За период выплаты" } }
}
public enum FinanceRounding: String, Codable, CaseIterable, Sendable { case halfUp, halfEven, truncate
    public var title: String { switch self { case .halfUp: return "Half-up"; case .halfEven: return "Half-even"; case .truncate: return "Усечение" } }
}
public enum RoundingPoint: String, Codable, CaseIterable, Sendable { case event, daily }
public enum AccrualBalance: String, Codable, CaseIterable, Sendable { case openingDay, closingDay, minimumPeriod }
public enum PaymentFrequency: String, Codable, CaseIterable, Sendable {
    case monthly, quarterly, yearly, weekly, fortnightly, twiceMonthly, everyNDays, maturity, manual
    public var title: String { switch self { case .monthly: return "Ежемесячно"; case .quarterly: return "Ежеквартально"; case .yearly: return "Ежегодно"; case .weekly: return "Еженедельно"; case .fortnightly: return "Каждые две недели"; case .twiceMonthly: return "Дважды в месяц"; case .everyNDays: return "Каждые N дней"; case .maturity: return "В конце срока"; case .manual: return "Ручной график" } }
}
public enum BusinessDayRule: String, Codable, CaseIterable, Sendable { case none, following, preceding, modifiedFollowing
    public var title: String { switch self { case .none: return "Без переноса"; case .following: return "Следующий рабочий"; case .preceding: return "Предыдущий рабочий"; case .modifiedFollowing: return "Следующий рабочий в этом месяце" } }
}
public struct BankCalendar: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var name: String; public var years: [Int]; public var holidays: [Day]; public var workingExceptions: [Day]; public var source: String
    public init(name: String, years: [Int], holidays: [Day] = [], workingExceptions: [Day] = [], source: String = "Введён вручную") { self.name = name; self.years = years; self.holidays = holidays; self.workingExceptions = workingExceptions; self.source = source }
}
public struct InterestTier: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var lowerMinor: Int64; public var annualPercent: String
    public init(lowerMinor: Int64, annualPercent: String) { self.lowerMinor = lowerMinor; self.annualPercent = annualPercent }
}
public enum TierMethod: String, Codable, CaseIterable, Sendable { case wholeBalance, marginal }
public struct DepositConditions: Codable, Equatable, Sendable {
    public var capitalize = false; public var payoutAccountID: UUID?
    public var accrualFrequency: PaymentFrequency?
    public var capitalizationFrequency: PaymentFrequency?
    public var roundOnlyAtFinalPayout: Bool?
    public var allowTopUp = true; public var allowWithdrawal = true; public var minimumBalance: Int64 = 0
    public var tierMethod = TierMethod.wholeBalance; public var tiers: [InterestTier] = []
    public var earlyAnnualPercent: String?; public var earlyFee: Int64 = 0
    public var renewalExpected = false; public var renewalDecisionOn: Day?; public var renewalAnnualPercent: String?
    public var taxPercent: String?; public var taxAmount: Int64?; public var taxKnown = false
    public var separateTaxFrequency: PaymentFrequency?
    public var taxPaymentAccountID: UUID?
    public init() {}
}
public enum CreditTransactionKind: String, Codable, CaseIterable, Sendable { case purchase, cash, transfer, balanceTransfer, other
    public var title: String { switch self { case .purchase: return "Покупка"; case .cash: return "Наличные"; case .transfer: return "Перевод"; case .balanceTransfer: return "Перенос долга"; case .other: return "Другое" } }
}
public enum GraceMode: String, Codable, CaseIterable, Sendable { case none, statement, transactionDays, cycleDays, promotion, manual
    public var title: String { switch self { case .none: return "Без льготы"; case .statement: return "До оплаты выписки"; case .transactionDays: return "N дней от операции"; case .cycleDays: return "N дней от начала цикла"; case .promotion: return "До конца промо-периода"; case .manual: return "Дата банка вручную" } }
}
public enum PostGraceAccrual: String, Codable, CaseIterable, Sendable { case afterDeadline, fromTransaction, fromCycle }
public enum MinimumPaymentMode: String, Codable, CaseIterable, Sendable { case fixed, percent, percentPlusCharges, manual }
public enum RepaymentOrder: String, Codable, CaseIterable, Sendable { case chargesFirst, principalFirst, fifo, highestRate, proportional, manual
    public var title: String { switch self { case .chargesFirst: "Штрафы → комиссии → проценты → тело"; case .principalFirst: "Сначала тело"; case .fifo: "Сначала ранние транши"; case .highestRate: "Сначала высокая ставка"; case .proportional: "Пропорционально"; case .manual: "Вручную при платеже" } }
}
public enum StatementPaymentOrder: String, Codable, CaseIterable, Sendable {
    case manual, oldestFirst, newestFirst
    public var title: String { switch self { case .manual: "По распределению банка"; case .oldestFirst: "Сначала ранняя выписка"; case .newestFirst: "Сначала новая выписка" } }
}
public enum LateCreditPosting: String, Codable, CaseIterable, Sendable {
    case sameDay, nextDay, nextBusinessDay
    public var title: String { switch self { case .sameDay: "В тот же день"; case .nextDay: "На следующий календарный день"; case .nextBusinessDay: "На следующий рабочий день" } }
}
public struct CreditBucketRule: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var kind: CreditTransactionKind; public var annualPercent: String?; public var eligibleForGrace: Bool; public var feeMinor: Int64 = 0; public var feePercent: String?
    public init(kind: CreditTransactionKind, annualPercent: String? = nil, eligibleForGrace: Bool = true) { self.kind = kind; self.annualPercent = annualPercent; self.eligibleForGrace = eligibleForGrace }
}
public struct CreditConditions: Codable, Equatable, Sendable {
    public var limit: Int64 = 0; public var chargesUseLimit = true
    public var closingDay = 1; public var dueDays = 25; public var grace = GraceMode.statement; public var graceDays = 55; public var graceEnd: Day?
    public var minimumMode = MinimumPaymentMode.percent; public var minimumPercent = "5"; public var minimumFloor: Int64 = 0; public var minimumFixed: Int64 = 0
    public var accrualAfterGrace = PostGraceAccrual.afterDeadline; public var repaymentOrder = RepaymentOrder.chargesFirst
    public var excessRepaymentOrder: RepaymentOrder?; public var lateFee: Int64 = 0; public var penaltyAnnualPercent: String?
    public var requiresMinimumForGrace = true; public var carriedDebtLosesGrace = false
    public var statementPaymentOrder: StatementPaymentOrder?
    /// Number of consecutive fully paid statements needed to restore purchase grace.
    public var graceRestoreStatements: Int?
    /// nil leaves penalty restoration unknown; true ends when the missed minimum is paid.
    public var penaltyUntilMinimumPaid: Bool?
    public var penaltyEnd: Day?
    public var buckets: [CreditBucketRule] = [CreditBucketRule(kind: .purchase), CreditBucketRule(kind: .cash, eligibleForGrace: false), CreditBucketRule(kind: .transfer, eligibleForGrace: false), CreditBucketRule(kind: .balanceTransfer)]
    public init() {}
}
public enum AmortizationMethod: String, Codable, CaseIterable, Sendable { case annuity, differentiated, interestOnly, manual
    public var title: String { switch self { case .annuity: return "Аннуитет"; case .differentiated: return "Дифференцированный"; case .interestOnly: return "Только проценты; тело в конце"; case .manual: return "Ручной график" } }
}
public enum PrepaymentMode: String, Codable, CaseIterable, Sendable { case reduceTerm, reducePayment, manual }
public struct LoanConditions: Codable, Equatable, Sendable {
    public var method = AmortizationMethod.annuity; public var paymentOverride: Int64?
    public var escrowAccountID: UUID?; public var escrowPayment: Int64 = 0
    public var paymentFee: Int64 = 0; public var prepaymentFeePercent: String?; public var freePrepaymentLimit: Int64?
    public var holidayEnd: Day?; public var accrueDuringHoliday = true; public var capitalizeDuringHoliday = false
    public var interestOnlyEnd: Day?; public var fixedDealEnd: Day?; public var allowNegativeAmortization = false
    public init() {}
}
public struct FinancialTerms: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var effectiveFrom: Day; public var annualPercent: String?
    public var rateKind = RateKind.nominalAnnual; public var basis = InterestBasis.actual365
    public var rounding = FinanceRounding.halfUp; public var roundingPoint = RoundingPoint.event; public var balanceBasis = AccrualBalance.closingDay
    public var includeFirstDay = true; public var includeLastDay = false
    public var indexName = ""; public var indexPercent: String?; public var marginPercent: String?; public var floorPercent: String?; public var capPercent: String?
    public var resetOn: Day?; public var scenarioRate = false; public var comparisonRateLabel = ""; public var comparisonRate: String?
    public var deposit = DepositConditions(); public var credit = CreditConditions(); public var loan = LoanConditions()
    public var source = "Введено вручную"
    public init(effectiveFrom: Day = .today, annualPercent: String? = nil) { self.effectiveFrom = effectiveFrom; self.annualPercent = annualPercent }
    public func rate() throws -> Decimal? {
        var value: Decimal?
        if !indexName.isEmpty { if let indexPercent, let marginPercent { value = try Money.decimal(indexPercent) + Money.decimal(marginPercent) } }
        else if let annualPercent { value = try Money.decimal(annualPercent) }
        if let floorPercent, let current = value { value = max(current, try Money.decimal(floorPercent)) }
        if let capPercent, let current = value { value = min(current, try Money.decimal(capPercent)) }
        return value.map { $0 / 100 }
    }
}
public enum FinancialComponent: String, Codable, CaseIterable, Sendable { case principal, interest, fee, penalty, tax, escrow, unallocated, ownFunds
    public var title: String { switch self { case .principal: return "Основной долг / тело"; case .interest: return "Проценты"; case .fee: return "Комиссия"; case .penalty: return "Штраф"; case .tax: return "Налог"; case .escrow: return "Escrow"; case .unallocated: return "Не распределено"; case .ownFunds: return "Собственные средства" } }
}
public struct FinancialAllocation: Codable, Equatable, Sendable {
    public var component: FinancialComponent; public var amount: Int64; public var lotID: UUID?
    public init(_ component: FinancialComponent, _ amount: Int64, lotID: UUID? = nil) { self.component = component; self.amount = amount; self.lotID = lotID }
}
public struct FinanceOperationDetails: Codable, Equatable, Sendable {
    public var version = 1; public var groupID: UUID?; public var eventID: String?; public var contractID: UUID?
    public var component = FinancialComponent.principal; public var transactionKind = CreditTransactionKind.purchase
    public var contractViolationConfirmed: Bool?; public var consequenceUnknown: Bool?
    public var creditedAt: Date?
    public var statementAllocations: [CreditStatementAllocation]?
    public var allocations: [FinancialAllocation] = []; public var prepayment = false
    public var prepaymentMode: PrepaymentMode?
    public var prepaymentRegularPayment: Int64?
    public var prepaymentScheduleEnd: Day?
    public init(component: FinancialComponent = .principal, allocations: [FinancialAllocation] = []) { self.component = component; self.allocations = allocations }
}
public enum FinanceEventKind: String, Codable, CaseIterable, Sendable { case scheduledPayment, depositInterest, depositMaturity, renewalDecision, loanPayment, gracePayment, minimumPayment, rateChange, insurance, tax, other
    public var title: String { switch self { case .scheduledPayment: return "Запланированный расход"; case .depositInterest: return "Выплата процентов"; case .depositMaturity: return "Окончание депозита"; case .renewalDecision: return "Решение о пролонгации"; case .loanPayment: return "Платёж по кредиту"; case .gracePayment: return "Погашение для льготы"; case .minimumPayment: return "Минимальный платёж"; case .rateChange: return "Изменение ставки"; case .insurance: return "Страхование"; case .tax: return "Налог"; case .other: return "Другое" } }
}
public enum ForecastAccuracy: String, Codable, Sendable { case calculated, scenario, incomplete
    public var title: String { switch self { case .calculated: return "По заданным условиям"; case .scenario: return "Сценарий"; case .incomplete: return "Неполный расчёт" } }
}
public struct ManualFinanceRow: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var date: Day; public var kind: FinanceEventKind; public var components: [FinancialAllocation]; public var amount: Int64?; public var comment = ""
    public init(date: Day, kind: FinanceEventKind, components: [FinancialAllocation] = [], amount: Int64? = nil) { self.date = date; self.kind = kind; self.components = components; self.amount = amount }
}
public struct ContractReminders: Codable, Equatable, Sendable {
    public var enabled = true; public var paymentOffsets = [7, 3, 1, 0]; public var maturityOffsets = [30, 7, 1]; public var rateOffsets = [30, 7, 1]; public var interestEnabled = false
    public var hour = 9; public var minute = 0
    public init() {}
}
public struct FinancialContractPeriod: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var start: Day; public var end: Day?; public var principal: Int64; public var terms: [FinancialTerms]
    public init(start: Day, end: Day?, principal: Int64, terms: [FinancialTerms]) { self.start = start; self.end = end; self.principal = principal; self.terms = terms }
}
public struct FinancialContract: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var accountID: UUID; public var kind: AccountKind; public var market = FinancialMarket.ru
    public var productName = ""; public var note = ""; public var status = ContractStatus.active
    public var start: Day; public var end: Day?; public var originalPrincipal: Int64 = 0
    public var firstPayment: Day?; public var paymentDay: Int?; public var secondPaymentDay = 15
    public var frequency = PaymentFrequency.monthly; public var everyNDays = 30
    public var paymentAccountID: UUID?; public var calendarID: UUID?; public var businessDayRule = BusinessDayRule.none
    public var shiftAccrualWithPayment = false; public var timeZoneID = "Europe/Moscow"; public var cutoffHour: Int?
    public var lateCreditPosting: LateCreditPosting?
    public var forecastMonths = 12; public var terms: [FinancialTerms]; public var manualRows: [ManualFinanceRow] = []
    public var previousPeriods: [FinancialContractPeriod]?
    public var reminders = ContractReminders(); public var createdAt = Date(); public var modifiedAt = Date()
    public init(accountID: UUID, kind: AccountKind, start: Day = .today, end: Day? = nil, annualPercent: String? = nil) { self.accountID = accountID; self.kind = kind; self.start = start; self.end = end; self.terms = [FinancialTerms(effectiveFrom: start, annualPercent: annualPercent)] }
    public func terms(on day: Day) -> FinancialTerms? { terms.filter { $0.effectiveFrom <= day }.max { $0.effectiveFrom < $1.effectiveFrom } }
}
public struct CreditStatement: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var contractID: UUID; public var start: Day; public var closedOn: Day; public var dueOn: Day
    public var balance: Int64; public var minimum: Int64; public var graceAmount: Int64; public var source = "Выписка банка"
    public init(contractID: UUID, start: Day, closedOn: Day, dueOn: Day, balance: Int64, minimum: Int64, graceAmount: Int64) { self.contractID = contractID; self.start = start; self.closedOn = closedOn; self.dueOn = dueOn; self.balance = balance; self.minimum = minimum; self.graceAmount = graceAmount }
}
public struct CreditStatementAllocation: Codable, Equatable, Sendable {
    public var statementID: UUID; public var amount: Int64
    public init(statementID: UUID, amount: Int64) { self.statementID = statementID; self.amount = amount }
}
public struct FinanceFulfillment: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var eventID: String; public var contractID: UUID; public var operationIDs: [UUID]; public var amount: Int64
    public init(eventID: String, contractID: UUID, operationIDs: [UUID], amount: Int64) { self.eventID = eventID; self.contractID = contractID; self.operationIDs = operationIDs; self.amount = amount }
}
public struct FinanceOperationGroup: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var contractID: UUID; public var operationIDs: [UUID]; public var eventID: String?; public var title: String
    public var importSourceKey: String?
    public var importRowFingerprint: String?
    public var importMappingFingerprint: String?
    public init(contractID: UUID, operationIDs: [UUID], eventID: String? = nil, title: String) { self.contractID = contractID; self.operationIDs = operationIDs; self.eventID = eventID; self.title = title }
}
public struct UserBank: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString; public var name: String; public var country = FinancialMarket.other; public var logo: Data?; public var archived = false; public var catalogID: String?; public var note = ""
    public init(name: String, country: FinancialMarket = .other, logo: Data? = nil) { self.name = name; self.country = country; self.logo = logo }
}
public struct FinancialReminderSettings: Codable, Equatable, Sendable {
    public var eventSnoozedUntil: [String: Date]?
    public var systemEnabled = false; public var deliveredKeys: [String] = []; public var snoozedUntil: [String: Date] = [:]; public var scheduledThrough: Day?
    public init() {}
}
public struct FinancialBook: Codable, Equatable, Sendable {
    public var scheduledPayments: [ScheduledPayment]?
    public var contracts: [FinancialContract] = []; public var statements: [CreditStatement] = []; public var groups: [FinanceOperationGroup] = []; public var fulfillments: [FinanceFulfillment] = []
    public var banks: [UserBank] = []; public var calendars: [BankCalendar] = []; public var reminders = FinancialReminderSettings()
    public init() {}
}
public struct FinanceEvent: Identifiable, Equatable, Sendable {
    public var id: String; public var contractID: UUID; public var kind: FinanceEventKind; public var date: Day; public var accrualEnd: Day; public var components: [FinancialAllocation]; public var amount: Int64?; public var remaining: Int64?; public var balanceAfter: Int64?; public var accuracy: ForecastAccuracy; public var notes: [String]
    public var isFulfilled: Bool { remaining == 0 && amount != nil }
    public func amount(_ component: FinancialComponent) -> Int64 { components.filter { $0.component == component }.reduce(0) { $0 + $1.amount } }
}
public struct DebtSummary: Equatable, Sendable {
    public var balance: Int64; public var debt: Int64; public var ownFunds: Int64; public var components: [FinancialAllocation]; public var limit: Int64?; public var usedLimit: Int64?; public var available: Int64?; public var overLimit: Int64?
    public func amount(_ component: FinancialComponent) -> Int64 { components.filter { $0.component == component }.reduce(0) { $0 + $1.amount } }
}

extension Database {
    public var financeData: FinancialBook { get { finances ?? FinancialBook() } set { finances = newValue } }
    public func contract(for accountID: UUID) -> FinancialContract? { finances?.contracts.first { $0.accountID == accountID } }
    public func financialBankName(_ id: String?) -> String? { guard let id else { return nil }; return finances?.banks.first { $0.id == id }?.name ?? BankCatalog.get(id)?.name }
}
