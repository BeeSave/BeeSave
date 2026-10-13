import XCTest
@testable import BudgetCore

final class PlanningIntegrationTests: XCTestCase {
    func testExecutableToolContractAndRestrictedProjection() throws {
        var db = Database(); let p = Project(name:"Fictional shared project"); db.projects = [p]
        let session = PlanningToolSession(),access = PlanningAccess(actorID:UUID(),projectIDs:[p.id],sessionID:session.id)
        let encoder = JSONEncoder(),decoder = JSONDecoder()
        let response = try decoder.decode(PlanningToolResponse.self,from:PlanningTools.execute(encoder.encode(PlanningToolRequest(name:"project.read",projectID:p.id)),db:db,access:access,session:session))
        XCTAssertEqual(response.project,p); XCTAssertEqual(response.evidenceRefs,["project:" + p.id.uuidString])
        XCTAssertThrowsError(try PlanningTools.execute(encoder.encode(PlanningToolRequest(name:"plan.calculate",through:.today.adding(10))),db:db,access:access,session:session))
        var request = PlanningToolRequest(name:"project.read",projectID:p.id); request.version = 99
        XCTAssertThrowsError(try PlanningTools.execute(encoder.encode(request),db:db,access:access,session:session))
        request.version = 1; session.revoke(); XCTAssertThrowsError(try PlanningTools.execute(encoder.encode(request),db:db,access:access,session:session))
    }
    func testAgentReadsCalculatesExplainsAndOnlyProposesSettings() throws {
        var db = Database(); let account = Account(name:"Fictional",currency:"RUB"); try Ledger.saveAccount(account,opening:100_000,in:&db)
        var flow = PlanFlow(title:"Fictional bill",purpose:.payment,amount:20_000,currency:"RUB",start:.today); flow.frequency = .once; try PlanningLedger.saveFlow(flow,in:&db)
        let session = PlanningToolSession(),agent = PlanningAccess(actorID:db.id,fullPlan:true,sessionID:session.id)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; let decoder = JSONDecoder()
        func run(_ request:PlanningToolRequest) throws -> PlanningToolResponse { try decoder.decode(PlanningToolResponse.self,from:PlanningTools.execute(encoder.encode(request),db:db,access:agent,session:session)) }
        XCTAssertEqual(try run(PlanningToolRequest(name:"plan.read")).flows,[flow])
        var tax = TaxProfile(); tax.grossEmployment = 300_000_000; tax.withheld = 40_200_000
        var taxRequest = PlanningToolRequest(name:"tax.calculate"); taxRequest.profile = tax
        let firstTax = try run(taxRequest),secondTax = try run(taxRequest); XCTAssertEqual(firstTax,secondTax); XCTAssertEqual(firstTax.tax?.tax,40_200_000); XCTAssertFalse(firstTax.evidenceRefs.isEmpty)
        let events = try PlanningEvents.list(db:db); var explain = PlanningToolRequest(name:"event.explain"); explain.eventID = try XCTUnwrap(events.first).id
        XCTAssertEqual(try run(explain).event?.reason,events.first?.reason)
        var draftFlow = flow; draftFlow.amount = 30_000
        var compare = PlanningToolRequest(name:"scenario.compare",through:.today); compare.scenario = PlanScenario(title:"Fictional variant",snapshotRevision:0,flows:[draftFlow],reserve:0,currency:"RUB")
        XCTAssertEqual(try run(compare).ending,70_000); XCTAssertEqual(try run(compare).baselineEnding,80_000); XCTAssertEqual(db.planningData.flows,[flow])
        compare.scenario?.snapshotRevision = 99; XCTAssertThrowsError(try run(compare))
        var settings = db.planningData.eventSettings; settings.paymentDays = 3
        let proposed = PlanningProposal(revision:0,command:.settings(settings),explanation:"Fictional suggestion")
        let request = PlanningToolRequest(name:"plan.propose",proposal:proposed); let response = try run(request)
        XCTAssertEqual(response,try run(request)); XCTAssertEqual(db.planningData.eventSettings.paymentDays,7)
        XCTAssertThrowsError(try PlanningActions.apply(try XCTUnwrap(response.proposal),requestID:UUID(),access:agent,session:session,in:&db))
        let human = PlanningAccess(actorID:db.id,fullPlan:true,canApply:true,sessionID:session.id)
        _ = try PlanningActions.apply(try XCTUnwrap(response.proposal),requestID:UUID(),access:human,session:session,in:&db)
        XCTAssertEqual(db.planningData.eventSettings.paymentDays,3); XCTAssertEqual(db.operations.count,1)
        session.revoke(); XCTAssertThrowsError(try run(taxRequest))
    }
    func testCompanyCashAndFinancingAreSeparateFromPersonalPlan() throws {
        var db = Database(); var p = Project(name:"Fictional cafe"); var d = ProjectDetails(); d.type = .business; p.details = d; try PlanningLedger.saveProject(p,in:&db)
        let own = Account(name:"Own",currency:"RUB"); try Ledger.saveAccount(own,opening:100_000,in:&db)
        var company = Account(name:"Company",currency:"RUB"); company.businessProjectID = p.id; try Ledger.saveAccount(company,opening:5_000_000,in:&db)
        var flow = PlanFlow(title:"Company sales",purpose:.income,amount:100_000,currency:"RUB",start:.today); flow.accountID = company.id; flow.frequency = .once; try PlanningLedger.saveFlow(flow,in:&db)
        XCTAssertEqual(try PlanningEngine.projection(db:db,through:.today,financeEvents:[]).opening,100_000)
        XCTAssertEqual(try PlanningEngine.projection(db:db,through:.today,financeEvents:[]).ending,100_000)
        let contribution = ProjectFact(date:.today,amount:100_000); var fact = contribution; fact.kind = .contribution; fact.income = true; fact.confirmed = true; db.projects[0].details!.facts.append(fact)
        XCTAssertEqual(try ProjectEngine.summary(project:db.projects[0],db:db).income,0)
    }
    func testEditedFactScalesAllocationAndPreservesObservation() throws {
        var db = Database(); let a = Account(name:"Fictional card",currency:"RUB"); try Ledger.saveAccount(a,opening:100_000,in:&db)
        let flow = PlanFlow(title:"Life",purpose:.living,amount:50_000,currency:"RUB",start:.today); try PlanningLedger.saveFlow(flow,in:&db)
        var op = try XCTUnwrap(Reconciliation.save(accountID:a.id,observed:80_000,reason:"Test",mode:.expense,expectedRevision:0,in:&db))
        try PlanningLedger.allocate(PlanAllocation(occurrenceID:PlanningEngine.key(flow,anchor:.today),operationID:op.id,sourceAmount:20_000,amount:20_000),in:&db)
        let source = op.reconciliation; op.amount = 10_000; try Ledger.saveOperation(op,in:&db)
        XCTAssertEqual(db.planningData.allocations.first?.amount,10_000)
        XCTAssertEqual(try PlanningEngine.occurrences(flow:flow,db:db,from:.today,through:.today).first?.remaining,40_000)
        XCTAssertEqual(db.operations.first { $0.id == op.id }?.reconciliation,source)
        op.reconciliation = nil; XCTAssertThrowsError(try Ledger.saveOperation(op,in:&db))
    }
    func testRestorationMigratesSchemaThreeAndReproducesNewPlan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = VaultStore(url:root.appendingPathComponent("v.beesave")); defer { store.close() }
        var old = Database(); old.version = 3; let p = Project(name:"Fictional old project"); old.projects = [p]
        let key = try VaultCrypto.random(),bootstrap = Bootstrap(databaseID:old.id,password:nil,recovery:Data())
        try store.restore(database:old,dataKey:key,bootstrap:bootstrap,safetyCopy:nil)
        XCTAssertEqual(store.db?.version,4); XCTAssertEqual(store.db?.projects[0].id,p.id); XCTAssertEqual(store.db?.projects[0].details?.migrated,true)
        try store.transaction { var flow = PlanFlow(title:"Future bill",purpose:.payment,amount:100,currency:"RUB",start:.today.adding(3)); flow.frequency = .once; try PlanningLedger.saveFlow(flow,in:&$0) }
        let db = try XCTUnwrap(store.db),copy = root.appendingPathComponent("backup.mubak"); try store.backup(to:copy)
        XCTAssertEqual(try VaultFile.read(Data(contentsOf:copy)).decrypt(key:key),db)
    }
    func testChartDoesNotTurnTransfersIntoFlowsAndRetainsMissingData() throws {
        var db = Database(); let a = Account(name:"A",currency:"RUB"),b = Account(name:"B",currency:"RUB"); try Ledger.saveAccount(a,opening:10000,in:&db); try Ledger.saveAccount(b,in:&db)
        var transfer = BudgetCore.Operation(kind:.transfer,accountID:a.id,amount:1000); transfer.toAccountID = b.id; transfer.toAmount = 1000; try Ledger.saveOperation(transfer,in:&db)
        let rows = try PlanningCharts.monthly(db:db,from:.today.firstOfMonth,through:.today.lastOfMonth,cash:true,forecast:[])
        XCTAssertEqual(rows.first?.income,0); XCTAssertEqual(rows.first?.expense,0)
        let loanAccount = Account(name:"Loan",currency:"RUB"); var loan = loanAccount; loan.financialKind = .termLoan; try Ledger.saveAccount(loan,opening:-10000,in:&db)
        transfer.id = UUID(); transfer.toAccountID = loan.id; try Ledger.saveOperation(transfer,in:&db)
        XCTAssertEqual(try PlanningCharts.monthly(db:db,from:.today.firstOfMonth,through:.today.lastOfMonth,cash:true,forecast:[]).first?.expense,1000)
        XCTAssertEqual(try PlanningCharts.monthly(db:db,from:.today.firstOfMonth,through:.today.lastOfMonth,cash:false,forecast:[]).first?.expense,0)
    }
    func testCancellationAndCalculationIdentity() async throws {
        let db = Database()
        let a = try PlanningEngine.projection(db:db,through:.today.adding(10),financeEvents:[],opening:100)
        let b = try PlanningEngine.projection(db:db,through:.today.adding(10),financeEvents:[],opening:100)
        let c = try PlanningEngine.projection(db:db,through:.today.adding(10),financeEvents:[],opening:101)
        XCTAssertEqual(a.calculationID,b.calculationID); XCTAssertNotEqual(a.calculationID,c.calculationID)
        var large = db
        large.planningData.flows = (0..<10000).map { PlanFlow(title: "Fictional cancellation \($0)", purpose: .payment, amount: 100, currency: "RUB", start: .today) }
        let cancellable = large
        let worker = Task.detached { try PlanningEngine.projection(db:cancellable,through:FinanceMath.addingMonths(.today,60),financeEvents:[]) }
        await Task.yield()
        let cancellation = Date(); worker.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled computation applied") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        let duration = Date().timeIntervalSince(cancellation)
        XCTAssertLessThanOrEqual(duration, 1)
        print("PLANNING019_CANCEL seconds=\(duration)")
    }
    func testPlanningVolumeAndTenScenariosAC01922() throws {
        guard ProcessInfo.processInfo.environment["BEESAVE_PLANNING_PERF"] == "1" else { throw XCTSkip("Run Planning019 volume in Release") }
        var db = Database(); let category = db.categories[0].id
        db.accounts = (0..<100).map { Account(name:"Fictional account \($0)",currency:"RUB") }
        for i in 0..<100000 { var op = BudgetCore.Operation(kind:.expense,accountID:db.accounts[i%100].id,amount:100); op.categoryID = category; db.operations.append(op) }
        for i in 0..<100 { var f = PlanFlow(title:"Fictional series \(i)",purpose:.payment,amount:10000,currency:"RUB",start:.today); f.end = try FinanceMath.addingMonths(.today,59); db.planningData.flows.append(f) }
        for i in 0..<100 { var p = Project(name:"Fictional project \(i)"),d = ProjectDetails(); d.stage = .active; d.costs = (0..<40).map { ProjectCost(title:"Fictional work \($0)",amount:1000,dueOn:.today.adding($0+1)) }; p.details = d; db.projects.append(p) }
        let through = try FinanceMath.addingMonths(.today,60),start = Date()
        let result = try PlanningEngine.projection(db:db,through:through,financeEvents:[])
        let single = Date().timeIntervalSince(start); XCTAssertEqual(result.points.count,10000); XCTAssertLessThanOrEqual(single,2)
        let comparisons = Date(); for _ in 0..<10 { _ = try PlanningEngine.projection(db:db,through:through,financeEvents:[]) }; let all = Date().timeIntervalSince(comparisons)
        XCTAssertLessThanOrEqual(all,10); print("PLANNING019_PERF points=\(result.points.count) single=\(single) ten=\(all)")
    }
}
