import Foundation

public struct PlanningAccess: Sendable {
    public var actorID: UUID; public var projectIDs: Set<UUID>; public var fullPlan: Bool; public var canApply: Bool; public var sessionID: UUID
    public init(actorID: UUID, projectIDs: Set<UUID> = [], fullPlan: Bool = false, canApply: Bool = false, sessionID: UUID) {
        self.actorID = actorID; self.projectIDs = projectIDs; self.fullPlan = fullPlan; self.canApply = canApply; self.sessionID = sessionID
    }
}
public enum PlanningCommand: Codable, Equatable, Sendable {
    case flow(PlanFlow), goal(SavingsGoal), project(Project), tax(TaxProfile), settings(PlanningEventSettings)
    case forecastRates([FXRate]), forecastRate(FXRate), distribution(Int64,[IncomeAllocationRule]), accountView(Bool,String), reserve(Int64,String), allocate(PlanAllocation), executeFlow(Operation,PlanAllocation), approveProject(UUID,String), scenario(PlanScenario)
    case removeFlow(UUID), removeGoal(UUID)
    var entityID: UUID? { switch self { case .flow(let v): v.id; case .goal(let v): v.id; case .project(let v): v.id; case .tax(let v): v.id; case .allocate(let v): v.id; case .executeFlow(let v,_): v.id; case .approveProject(let id,_), .removeFlow(let id), .removeGoal(let id): id; case .scenario(let v): v.id; default: nil } }
}
public struct PlanningProposal: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var revision: UInt64; public var command: PlanningCommand; public var explanation: String
    public init(revision: UInt64, command: PlanningCommand, explanation: String) { self.revision = revision; self.command = command; self.explanation = explanation }
}
/// Lifetime belongs to the unlocked application session. Tools never receive a VaultStore.
public final class PlanningToolSession: @unchecked Sendable {
    private let lock = NSLock(); private var active = true
    public let id = UUID()
    public init() {}
    public func revoke() { lock.lock(); active = false; lock.unlock() }
    public func check(_ access: PlanningAccess) throws { lock.lock(); defer { lock.unlock() }; guard active && access.sessionID == id else { throw BudgetError.locked } }
}
public enum PlanningActions {
    public static func apply(_ proposal: PlanningProposal, requestID: UUID, access: PlanningAccess, session: PlanningToolSession, in db: inout Database) throws -> UUID {
        try session.check(access)
        guard access.canApply && access.actorID == db.id else { throw BudgetError.invalid("Изменение требует решения пользователя в приложении.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = VaultCrypto.fingerprint(try encoder.encode(proposal))
        if let receipt = db.planningData.receipts.first(where: { $0.requestID == requestID }) {
            guard receipt.fingerprint == fingerprint else { throw BudgetError.conflict("Ключ запроса уже использован с другим содержимым.") }; return receipt.resultID
        }
        guard proposal.revision == (db.revision ?? 0) else { throw BudgetError.conflict("План изменился. Пересчитайте предложение.") }
        if !access.fullPlan {
            guard case .project(let p) = proposal.command, access.projectIDs.contains(p.id) else { throw BudgetError.invalid("Изменение вне разрешённой области.") }
        }
        var candidate = db
        switch proposal.command {
        case .flow(let v): try PlanningLedger.saveFlow(v,in:&candidate)
        case .goal(let v): try PlanningLedger.saveGoal(v,in:&candidate)
        case .project(let v): try PlanningLedger.saveProject(v,in:&candidate)
        case .allocate(let v): try PlanningLedger.allocate(v,in:&candidate)
        case .executeFlow(let operation,let allocation): try Ledger.saveOperation(operation,in:&candidate); try PlanningLedger.allocate(allocation,in:&candidate)
        case .approveProject(let id,let reason): try PlanningLedger.approveProject(id,reason:reason,in:&candidate)
        case .forecastRates(let rates):
            for rate in rates { _ = try Currency.get(rate.base); _ = try Currency.get(rate.quote); guard rate.base != rate.quote,try Money.decimal(rate.rate) > 0 else { throw BudgetError.invalid("Неверный прогнозный курс.") }; candidate.planningData.forecastRates.removeAll { $0.base == rate.base && $0.quote == rate.quote && $0.date == rate.date }; candidate.planningData.forecastRates.append(rate) }
        case .forecastRate(let rate):
            _ = try Currency.get(rate.base); _ = try Currency.get(rate.quote)
            guard rate.base != rate.quote,try Money.decimal(rate.rate) > 0 else { throw BudgetError.invalid("Неверный прогнозный курс.") }
            candidate.planningData.forecastRates.removeAll { $0.base == rate.base && $0.quote == rate.quote && $0.date == rate.date }; candidate.planningData.forecastRates.append(rate)
        case .distribution(let income,let rules): _ = try IncomeDistribution.calculate(netIncome:income,rules:rules); candidate.planningData.distributionIncome = income; candidate.planningData.allocationRules = rules
        case .accountView(let cards,let sort): candidate.planningData.accountCards = cards; candidate.planningData.accountSort = sort
        case .reserve(let amount,let currency): candidate.planningData.reserve = amount; candidate.planningData.reserveCurrency = currency
        case .settings(let settings): candidate.planningData.eventSettings = settings
        case .tax(let profile):
            var book = candidate.planningData
            if let i = book.taxes.firstIndex(where: { $0.id == profile.id }) { book.taxes[i] = profile } else { book.taxes.append(profile) }
            book.taxResults.append(try CountryModules.calculate(profile,revision:proposal.revision)); candidate.planningData = book
        case .scenario(let scenario):
            guard scenario.snapshotRevision == proposal.revision else { throw BudgetError.conflict("Сценарий устарел.") }
            let (next,overflow) = proposal.revision.addingReportingOverflow(1); guard !overflow else { throw BudgetError.overflow }; var saved = scenario; saved.snapshotRevision = next; candidate.planningData.scenarios.append(saved)
        case .removeFlow(let id):
            guard !candidate.planningData.allocations.contains(where: { $0.occurrenceID.hasPrefix(id.uuidString.lowercased()) }) else { throw BudgetError.conflict("Есть факт исполнения; отключите серию вместо удаления.") }
            candidate.planningData.flows.removeAll { $0.id == id }
        case .removeGoal(let id): candidate.planningData.goals.removeAll { $0.id == id }
        }
        let result = proposal.command.entityID ?? db.id
        candidate.planningData.audit.append(PlanningAudit(actor:access.actorID,action:String(describing:proposal.command).components(separatedBy:"(").first ?? "change",entityID:result,revision:proposal.revision,reason:proposal.explanation))
        candidate.planningData.receipts.append(PlanningReceipt(requestID:requestID,fingerprint:fingerprint,resultID:result))
        try PlanningLedger.validate(candidate); try session.check(access); db = candidate; return result
    }
    public static func readProject(_ id: UUID, db: Database, access: PlanningAccess, session: PlanningToolSession) throws -> Project {
        try session.check(access); guard access.fullPlan || access.projectIDs.contains(id) else { throw BudgetError.invalid("Проект вне разрешённой области.") }
        guard let p = db.projects.first(where: { $0.id == id }) else { throw BudgetError.missing("Проект не найден.") }; return p
    }
    public static func calculate(db: Database, through: Day, access: PlanningAccess, session: PlanningToolSession) throws -> PlanningProjection {
        try session.check(access); guard access.fullPlan else { throw BudgetError.invalid("Общая сводка вне разрешённой области.") }
        let result = try PlanningEngine.projection(db:db,through:through); try session.check(access); return result
    }
    public static func propose(_ command: PlanningCommand, db: Database, explanation: String, access: PlanningAccess, session: PlanningToolSession) throws -> PlanningProposal {
        try session.check(access); guard access.fullPlan else { throw BudgetError.invalid("Предложение вне разрешённой области.") }
        return PlanningProposal(revision:db.revision ?? 0,command:command,explanation:explanation)
    }
}
public struct IncomeAllocationRule: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var title: String; public var fixed: Int64?; public var percent: String?
    public init(title: String, fixed: Int64? = nil, percent: String? = nil) { self.title = title; self.fixed = fixed; self.percent = percent }
}
public enum IncomeDistribution {
    public static func calculate(netIncome: Int64, rules: [IncomeAllocationRule]) throws -> [Int64] {
        guard netIncome >= 0 else { throw BudgetError.invalid("Доход должен быть неотрицательным.") }
        let values = try rules.map { rule -> Int64 in
            guard (rule.fixed == nil) != (rule.percent == nil) else { throw BudgetError.invalid("Выберите сумму или процент чистого дохода.") }
            if let value = rule.fixed { guard value >= 0 else { throw BudgetError.invalid("Отрицательное распределение.") }; return value }
            let percent = try Money.decimal(rule.percent!); guard percent >= 0 && percent <= 100 else { throw BudgetError.invalid("Процент вне диапазона.") }
            return try FinanceMath.rounded(Money.divide(Money.multiply(Decimal(netIncome),percent),100))
        }
        let total = try values.reduce(Int64(0)) { try Money.add($0,$1) }; guard total <= netIncome else { throw BudgetError.conflict("Распределение превышает выбранный чистый доход.") }; return values
    }
}
