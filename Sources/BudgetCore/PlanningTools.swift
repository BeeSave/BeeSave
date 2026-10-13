import Foundation

public struct PlanningToolDefinition: Codable, Equatable, Sendable {
    public var name: String; public var version: Int; public var access: String
}
public struct PlanningToolRequest: Codable, Equatable, Sendable {
    public var name: String; public var version = 1; public var projectID: UUID?; public var through: Day?; public var proposal: PlanningProposal?; public var profile: TaxProfile?; public var eventID: String?; public var scenario: PlanScenario?
    public init(name: String, projectID: UUID? = nil, through: Day? = nil, proposal: PlanningProposal? = nil) { self.name = name; self.projectID = projectID; self.through = through; self.proposal = proposal }
}
public struct PlanningToolResponse: Codable, Equatable, Sendable {
    public var version = 1; public var snapshotRevision: UInt64; public var project: Project?; public var calculationID: String?; public var ending: Int64?; public var minimum: Int64?; public var firstViolation: Day?; public var currency: String?
    public var flows: [PlanFlow]?; public var goals: [SavingsGoal]?; public var tax: TaxCalculation?; public var event: PlanningToolEvent?; public var baselineEnding: Int64?
    public var assumptions: [String] = []; public var missing: [String] = []; public var evidenceRefs: [String] = []; public var proposal: PlanningProposal?
}
public struct PlanningToolEvent: Codable, Equatable, Sendable {
    public var id: String; public var sourceID: UUID; public var date: Day; public var reason: String; public var action: String; public var priority: Int
}
public enum PlanningTools {
    public static let registry: [PlanningToolDefinition] = [
        PlanningToolDefinition(name:"project.read",version:1,access:"read"),
        PlanningToolDefinition(name:"plan.read",version:1,access:"read"),
        PlanningToolDefinition(name:"scenario.compare",version:1,access:"calculate"),
        PlanningToolDefinition(name:"tax.calculate",version:1,access:"calculate"),
        PlanningToolDefinition(name:"event.explain",version:1,access:"read"),
        PlanningToolDefinition(name:"plan.calculate",version:1,access:"calculate"),
        PlanningToolDefinition(name:"plan.propose",version:1,access:"propose")
    ]
    /// The host supplies trusted access and session. Neither is decoded from agent input.
    public static func execute(_ input: Data, db: Database, access: PlanningAccess, session: PlanningToolSession) throws -> Data {
        guard input.count <= 1_048_576 else { throw BudgetError.invalid("Превышен объём запроса инструмента.") }
        try session.check(access)
        let request = try JSONDecoder().decode(PlanningToolRequest.self,from:input)
        guard registry.contains(where:{ $0.name == request.name && $0.version == request.version }) else { throw BudgetError.invalid("Неизвестная версия инструмента.") }
        var response = PlanningToolResponse(snapshotRevision:db.revision ?? 0)
        switch request.name {
        case "project.read":
            guard let id = request.projectID else { throw BudgetError.invalid("Нужен идентификатор проекта.") }
            response.project = try PlanningActions.readProject(id,db:db,access:access,session:session); response.evidenceRefs = ["project:" + id.uuidString]
        case "plan.read":
            guard access.fullPlan else { throw BudgetError.invalid("Общий план вне разрешённой области.") }
            response.flows = db.planningData.flows; response.goals = db.planningData.goals
            response.evidenceRefs = db.planningData.flows.map { "plan:" + $0.id.uuidString }
        case "tax.calculate":
            guard access.fullPlan,let profile = request.profile,profile.ownerID == nil || profile.ownerID == access.actorID else { throw BudgetError.invalid("Налоговый профиль вне разрешённой области.") }
            let result = try CountryModules.calculate(profile,revision:db.revision ?? 0)
            response.tax = result; response.assumptions = result.assumptions; response.missing = result.missing; response.evidenceRefs = result.rules?.sources ?? []
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            response.calculationID = VaultCrypto.fingerprint(try encoder.encode(profile)) + "." + (result.rules?.version ?? "unsupported") + ".\(db.revision ?? 0)"
            let digest = VaultCrypto.fingerprint(Data(response.calculationID!.utf8)); let raw = Array(digest.prefix(32)); let uuid = String(raw[0..<8]) + "-" + String(raw[8..<12]) + "-" + String(raw[12..<16]) + "-" + String(raw[16..<20]) + "-" + String(raw[20..<32])
            response.tax?.id = UUID(uuidString:uuid)!; response.tax?.date = Day.today.date
        case "event.explain":
            guard access.fullPlan,let id = request.eventID else { throw BudgetError.invalid("Событие вне разрешённой области.") }
            let projection = try PlanningActions.calculate(db:db,through:.today.adding(365),access:access,session:session)
            guard let event = try PlanningEvents.list(db:db,projection:projection).first(where:{ $0.id == id }) else { throw BudgetError.missing("Событие больше не актуально.") }
            response.event = PlanningToolEvent(id:event.id,sourceID:event.sourceID,date:event.date,reason:event.reason,action:event.action,priority:event.priority)
            response.calculationID = projection.calculationID; response.evidenceRefs = ["source:" + event.sourceID.uuidString,"event:" + event.id,"rules:planning.events.1"]
        case "scenario.compare":
            guard access.fullPlan,let scenario = request.scenario,scenario.snapshotRevision == (db.revision ?? 0),let through = request.through,through >= .today,through <= (try FinanceMath.addingMonths(.today,60)) else { throw BudgetError.conflict("Пересоздайте сценарий из текущей ревизии; горизонт до пяти лет.") }
            let base = try PlanningActions.calculate(db:db,through:through,access:access,session:session)
            let result = try PlanningEngine.scenario(scenario,db:db,through:through)
            response.baselineEnding = base.ending; response.calculationID = result.calculationID; response.ending = result.ending; response.minimum = result.minimum; response.firstViolation = result.firstViolation; response.currency = result.currency; response.assumptions = result.assumptions; response.missing = result.missing; response.evidenceRefs = ["scenario:" + scenario.id.uuidString]
        case "plan.calculate":
            guard let through = request.through,through >= .today,through <= (try FinanceMath.addingMonths(.today,60)) else { throw BudgetError.invalid("Горизонт инструмента — до пяти лет.") }
            let result = try PlanningActions.calculate(db:db,through:through,access:access,session:session)
            response.calculationID = result.calculationID; response.ending = result.ending; response.minimum = result.minimum; response.firstViolation = result.firstViolation; response.currency = result.currency; response.assumptions = result.assumptions; response.missing = result.missing; response.evidenceRefs = result.points.map { "event:" + $0.event.id }
        case "plan.propose":
            guard let proposal = request.proposal,proposal.revision == (db.revision ?? 0) else { throw BudgetError.conflict("Предложение устарело.") }
            response.proposal = try PlanningActions.propose(proposal.command,db:db,explanation:proposal.explanation,access:access,session:session); response.proposal?.id = proposal.id
        default: throw BudgetError.invalid("Инструмент не найден.")
        }
        try session.check(access)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(response)
    }
}
