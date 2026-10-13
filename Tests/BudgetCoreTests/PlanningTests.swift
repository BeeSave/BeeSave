import XCTest
@testable import BudgetCore

final class PlanningTests: XCTestCase {
    func fixture(balance: Int64 = 1_000_000) throws -> (Database,Account) {
        var db = Database(); let a = Account(name:"Fictional personal account",currency:"RUB",openedOn:.today.adding(-365))
        try Ledger.saveAccount(a,opening:balance,in:&db); return (db,a)
    }
    func expense(_ amount:Int64,account:Account,in db:inout Database) throws -> BudgetCore.Operation {
        var op = Operation(kind:.expense,accountID:account.id,amount:amount); op.categoryID = db.categories.first { $0.kind == .expense && $0.system }!.id; try Ledger.saveOperation(op,in:&db); return op
    }
    func testReconcileExpenseIncomeNeutralAndZero() throws {
        var (db,a) = try fixture(); let before = db.operations.count
        let op = try XCTUnwrap(Reconciliation.save(accountID:a.id,observed:760_000,reason:"Fictional living costs",mode:.expense,expectedRevision:0,in:&db))
        XCTAssertEqual(op.kind,.expense); XCTAssertEqual(op.amount,240_000); XCTAssertEqual(op.reconciliation?.balance,1_000_000); XCTAssertEqual(try db.balance(a.id),760_000); XCTAssertEqual(db.operations.count,before+1)
        XCTAssertEqual(try Reports.sum([op],db:db,currency:"RUB").known,240_000)
        _ = try Reconciliation.save(accountID:a.id,observed:960_000,reason:"Fictional income",mode:.income,expectedRevision:0,in:&db)
        XCTAssertEqual(try db.balance(a.id),960_000)
        _ = try Reconciliation.save(accountID:a.id,observed:900_000,reason:"Neutral",mode:.adjustment,expectedRevision:0,in:&db)
        let count = db.operations.count; XCTAssertNil(try Reconciliation.save(accountID:a.id,observed:900_000,reason:"",mode:.adjustment,expectedRevision:0,in:&db)); XCTAssertEqual(db.operations.count,count)
    }
    func testReconcileBudgetAndStaleOverflowArchive() throws {
        var (db,a) = try fixture(); let category = db.categories.first { $0.kind == .expense }!.id
        let prior = try expense(100_000,account:a,in:&db)
        var budget = Budget(kind:.monthly,name:"Fictional living",currency:"RUB",start:.today.firstOfMonth); budget.lines = [BudgetLine(categoryID:category,limit:300_000)]; try Ledger.saveBudget(budget,in:&db)
        _ = try Reconciliation.save(accountID:a.id,observed:660_000,reason:"Living",mode:.expense,categoryID:category,expectedRevision:0,in:&db)
        XCTAssertEqual(try Reports.sum(db.operations.filter { $0.kind == .expense },db:db,currency:"RUB").known,340_000)
        XCTAssertEqual(db.operations.filter { Ledger.matches($0,budget:budget,db:db) }.count,2)
        let saved = db
        XCTAssertThrowsError(try Reconciliation.save(accountID:a.id,observed:0,reason:"stale",mode:.expense,expectedRevision:1,in:&db)); XCTAssertEqual(db,saved)
        XCTAssertThrowsError(try Reconciliation.save(accountID:a.id,observed:Int64.min,reason:"overflow",mode:.expense,expectedRevision:0,in:&db)); XCTAssertEqual(db,saved)
        db.accounts[0].archived = true; XCTAssertThrowsError(try Reconciliation.save(accountID:a.id,observed:0,reason:"archived",mode:.expense,expectedRevision:0,in:&db)); XCTAssertNotNil(prior.id)
    }
    func testReconciliationSourceCSVAndOldNeutralMigration() throws {
        var (db,a) = try fixture(); let op = try XCTUnwrap(Reconciliation.save(accountID:a.id,observed:700_000,reason:"Fictional cost",mode:.expense,expectedRevision:0,in:&db))
        let bytes = try CSVCodec.export(db.operations,db:db); XCTAssertTrue(String(decoding:bytes,as:UTF8.self).contains("3,"))
        var options = ImportOptions(); options.createReferences = true
        let preview = try CSVImporter.preview(data:bytes,options:options,db:Database())
        XCTAssertTrue(preview.issues.isEmpty); XCTAssertEqual(preview.database.operations.first { $0.id == op.id }?.reconciliation,op.reconciliation)
        var old = db; old.version = 3; old.operations.removeAll { $0.reconciliation != nil }; old.planning = nil
        let migrated = try PlanningLedger.migrate(old); XCTAssertEqual(migrated.version,4); XCTAssertEqual(migrated.operations,old.operations)
    }
    func testMonthlyAnchorsExceptionsAndNoFacts() throws {
        var (db,_) = try fixture(); var flow = PlanFlow(title:"Fictional rent",purpose:.payment,amount:10000,currency:"RUB",start:try Day("2025-01-31"))
        try PlanningLedger.saveFlow(flow,in:&db)
        var rows = try PlanningEngine.occurrences(flow:flow,db:db,from:try Day("2025-01-01"),through:try Day("2025-03-31"))
        XCTAssertEqual(rows.map(\.date),try [Day("2025-01-31"),Day("2025-02-28"),Day("2025-03-31")]); XCTAssertEqual(db.operations.count,1)
        var e = PlanException(anchor:try Day("2025-02-28")); e.date = try Day("2025-03-02"); e.amount = 5000; flow.exceptions = [e]
        rows = try PlanningEngine.occurrences(flow:flow,db:db,from:try Day("2025-03-01"),through:try Day("2025-03-31")); XCTAssertEqual(rows.count,2); XCTAssertEqual(rows.first?.remaining,5000)
        e.closed = true; flow.exceptions = [e]; XCTAssertEqual(try PlanningEngine.occurrences(flow:flow,db:db,from:try Day("2025-02-01"),through:try Day("2025-03-31")).first?.remaining,0)
    }
    func testPartialLivingFactAndDeletion() throws {
        var (db,a) = try fixture(); let flow = PlanFlow(title:"Life",purpose:.living,amount:4_000_000,currency:"RUB",start:.today)
        try PlanningLedger.saveFlow(flow,in:&db); let op = try expense(1_500_000,account:a,in:&db)
        try PlanningLedger.allocate(PlanAllocation(occurrenceID:PlanningEngine.key(flow,anchor:.today),operationID:op.id,sourceAmount:op.amount,amount:op.amount),in:&db)
        XCTAssertEqual(try PlanningEngine.occurrences(flow:flow,db:db,from:.today,through:.today).first?.remaining,2_500_000)
        try Ledger.deleteOperation(op.id,in:&db); XCTAssertTrue(db.planningData.allocations.isEmpty); XCTAssertEqual(try PlanningEngine.occurrences(flow:flow,db:db,from:.today,through:.today).first?.remaining,4_000_000)
    }
    func testProjectionAndIntermediateDeficit() throws {
        var (db,_) = try fixture(balance:10_000_000); db.planningData.reserve = 5_000_000
        for (name,purpose,amount) in [("income",PlanPurpose.income,20_000_000),("life",.living,8_000_000),("mortgage",.payment,4_000_000),("casco",.payment,6_000_000),("project",.payment,5_000_000)] {
            var flow = PlanFlow(title:name,purpose:purpose,amount:Int64(amount),currency:"RUB",start:.today.adding(purpose == .income ? 1 : 2)); flow.frequency = .once; try PlanningLedger.saveFlow(flow,in:&db)
        }
        let result = try PlanningEngine.projection(db:db,through:.today.adding(3),financeEvents:[]); XCTAssertEqual(result.ending,7_000_000); XCTAssertEqual(result.ending-result.reserve,2_000_000)
        db.planningData.flows = []; db.planningData.reserve = 0
        var out = PlanFlow(title:"out",purpose:.payment,amount:3_000_000,currency:"RUB",start:.today.adding(1)); out.frequency = .once
        var incoming = PlanFlow(title:"in",purpose:.income,amount:10_000_000,currency:"RUB",start:.today.adding(2)); incoming.frequency = .once
        db.planningData.flows = [out,incoming]
        let deficit = try PlanningEngine.projection(db:db,through:.today.adding(3),financeEvents:[],opening:2_000_000); XCTAssertEqual(deficit.minimum,-1_000_000); XCTAssertEqual(deficit.ending,9_000_000); XCTAssertEqual(deficit.firstViolation,.today.adding(1))
    }
    func testUnknownConditionalAndMultiCurrencyNotZero() throws {
        var (db,_) = try fixture(); var flow = PlanFlow(title:"uncertain",purpose:.income,amount:100_000,currency:"RUB",start:.today); flow.certainty = .conditional; flow.frequency = .once
        db.planningData.flows = [flow]; XCTAssertTrue(try PlanningEngine.events(db:db,from:.today,through:.today,financeEvents:[]).isEmpty)
        XCTAssertEqual(try PlanningEngine.events(db:db,from:.today,through:.today,financeEvents:[],includeConditional:true).count,1)
        flow.currency = "USD"; flow.purpose = .payment; flow.certainty = .committed; db.planningData.flows = [flow]
        XCTAssertFalse(try PlanningEngine.projection(db:db,through:.today,financeEvents:[]).complete)
        flow.currency = "RUB"; flow.amount = nil; db.planningData.flows = [flow]; XCTAssertFalse(try PlanningEngine.projection(db:db,through:.today,financeEvents:[]).complete)
    }
    func testScheduledPaymentAliasHasOneRemainingFlow() throws {
        var (db,_) = try fixture(); let p = ScheduledPayment(title:"Fictional installment",comment:"Test",amount:10000,currency:"RUB",dueOn:.today.adding(1)); try ScheduledPayments.save(p,in:&db)
        var flow = PlanFlow(title:p.title,purpose:.payment,amount:p.amount,currency:p.currency,start:p.dueOn); flow.scheduledPaymentID = p.id; db.planningData.flows = [flow]
        XCTAssertEqual(try PlanningEngine.events(db:db,from:.today,through:.today.adding(2),financeEvents:[]).count,1)
    }
    func testPartnerRepairFactsAndVersionPreservation() throws {
        var (db,a) = try fixture(); var p = Project(name:"Fictional renovation"),d = ProjectDetails(); d.type = .renovation; d.stage = .active; d.reserve = 10_000_000
        let party = ProjectParticipant(name:"Fictional partner"); d.participants = [party]
        var contracted = ProjectCost(title:"Contract",amount:70_000_000,dueOn:.today.adding(1)); contracted.contracted = true
        let uncommitted = ProjectCost(title:"Future work",amount:20_000_000,dueOn:.today.adding(2)); d.costs = [contracted,uncommitted]
        var f = ProjectFact(date:.today,amount:30_000_000); f.costID = contracted.id; f.participantID = party.id; f.confirmed = true; d.facts = [f]; p.details = d
        try PlanningLedger.saveProject(p,in:&db)
        var summary = try ProjectEngine.summary(project:p,db:db); XCTAssertEqual(summary.forecast,100_000_000); XCTAssertEqual(summary.userPaid,0); XCTAssertEqual(try db.balance(a.id),1_000_000)
        var next = ProjectFact(date:.today,amount:10_000_000); next.costID = contracted.id; next.participantID = party.id; next.confirmed = true; p.details!.facts.append(next)
        try PlanningLedger.saveProject(p,in:&db); summary = try ProjectEngine.summary(project:p,db:db); XCTAssertEqual(summary.forecast,100_000_000); XCTAssertEqual(summary.paid,40_000_000)
        try PlanningLedger.approveProject(p.id,reason:"Fictional approval",in:&db)
        XCTAssertThrowsError(try PlanningLedger.saveProject(p,in:&db)); XCTAssertEqual(db.projects[0].details?.versions.count,1)
    }
    func testBusinessIncomeSplitAndLoanScenarios() throws {
        var a = ProjectParticipant(name:"A"),b = ProjectParticipant(name:"B"); a.incomePercent = "60"; b.incomePercent = "40"
        XCTAssertEqual(try ProjectEngine.splitIncome(100_000,participants:[a,b]).map(\.1),[60_000,40_000]); XCTAssertEqual(try ProjectEngine.splitIncome(1,participants:[a,b]).map(\.1).reduce(0,+),1)
        var m = BusinessModel(); m.initial = 600_000; m.revenue = 200_000; m.fixed = 50_000; m.variable = 100_000; XCTAssertEqual(try ProjectEngine.business(m).monthlyResult,50_000); XCTAssertEqual(try ProjectEngine.business(m).paybackMonths,12); XCTAssertEqual(try ProjectEngine.business(m).breakEvenRevenue,100_000)
        var loan = ProjectLoan(); loan.principal = 10_000_000; loan.annualPercent = "12"; loan.months = 120; loan.firstPayment = .today.adding(30)
        let base = try ProjectEngine.loanSchedule(loan),date = try FinanceMath.addingMonths(loan.firstPayment,3)
        let term = try ProjectEngine.loanSchedule(loan,prepayments:[ProjectPrepayment(date:date,amount:2_000_000,mode:.reduceTerm)])
        let payment = try ProjectEngine.loanSchedule(loan,prepayments:[ProjectPrepayment(date:date,amount:2_000_000,mode:.reducePayment)])
        XCTAssertEqual(base.last?.remaining,0); XCTAssertEqual(term.last?.remaining,0); XCTAssertEqual(payment.last?.remaining,0); XCTAssertLessThan(term.last!.date,base.last!.date); XCTAssertEqual(payment.last?.date,base.last?.date)
        XCTAssertLessThan(try term.reduce(Int64(0)) { try Money.add($0,$1.interest) },try base.reduce(Int64(0)) { try Money.add($0,$1.interest) })
        XCTAssertEqual(try term.reduce(Int64(0)) { try Money.add($0,Money.add($1.principal,$1.extra)) },loan.principal)
    }
    func testTaxMarginalBracketsAndJointDeductions() throws {
        for (rubles,tax) in [(0,0),(2_400_000,312_000),(5_000_000,702_000),(20_000_000,3_402_000),(50_000_000,9_402_000),(60_000_000,11_602_000)] { XCTAssertEqual(try RussiaPersonalTaxModule.employmentTax(base:Int64(rubles)*100),Int64(tax)*100) }
        var p = TaxProfile(); p.grossEmployment = 300_000_000; p.withheld = 40_200_000; p.housingEligible = true; p.housingCost = 200_000_000; p.interestEligible = true; p.interestCost = 100_000_000; p.socialEligible = true; p.treatment = 20_000_000
        let r = try CountryModules.calculate(p,revision:0); XCTAssertTrue(r.complete); XCTAssertEqual(r.socialBase,15_000_000); XCTAssertEqual(r.housingBase,200_000_000); XCTAssertEqual(r.interestBase,85_000_000); XCTAssertEqual(r.tax,0); XCTAssertEqual(r.refund,40_200_000)
        p.incomeIsNet = true; let net = try CountryModules.calculate(p,revision:0); XCTAssertFalse(net.complete); XCTAssertNil(net.tax)
        p.incomeIsNet = false; p.year = 2027; XCTAssertFalse(try CountryModules.calculate(p,revision:0).complete)
        p.year = 2026; p.country = "US"; XCTAssertFalse(try CountryModules.calculate(p,revision:0).complete)
    }
    func testSocialChildExpensivePriorAndInsufficientIncome() throws {
        var p = TaxProfile(); p.socialEligible = true; p.grossEmployment = 30_000_000; p.withheld = 3_900_000; p.treatment = 15_000_000; p.socialUsed = 5_000_000; p.expensiveTreatment = 10_000_000; p.childEducation = [ChildEducationCost(eligibleCost:11_000_000,claimedByOtherParent:5_000_000)]
        let r = try CountryModules.calculate(p,revision:0); XCTAssertEqual(r.socialBase,26_000_000); XCTAssertEqual(r.tax,520_000); XCTAssertEqual(r.refund,3_380_000)
        p.grossEmployment = 5_000_000; XCTAssertEqual(try CountryModules.calculate(p,revision:0).socialBase,5_000_000)
    }
    func testAttentionDedupSnoozeAndModifiedRisk() throws {
        var (db,_) = try fixture(); let p = ScheduledPayment(title:"Fictional insurance",comment:"Test",amount:10000,currency:"RUB",dueOn:.today.adding(1)); try ScheduledPayments.save(p,in:&db)
        var rows = try PlanningEvents.list(db:db,financeEvents:[]); XCTAssertEqual(rows.count,1)
        let key = rows[0].id; db.planningData.eventSettings.snoozed[key] = .today.adding(2); XCTAssertTrue(try PlanningEvents.list(db:db,financeEvents:[]).isEmpty)
        rows = try PlanningEvents.list(db:db,today:.today.adding(2),financeEvents:[]); XCTAssertEqual(rows.count,1)
        db.planningData.eventSettings.hiddenKeys = [key]; db.finances!.scheduledPayments![0].amount = 20000; XCTAssertEqual(try PlanningEvents.list(db:db,financeEvents:[]).count,1)
    }
    func testToolsHumanApplyIdempotencyConflictAndRevocation() throws {
        var (db,_) = try fixture(); let session = PlanningToolSession()
        let reader = PlanningAccess(actorID:db.id,fullPlan:true,canApply:false,sessionID:session.id)
        let writer = PlanningAccess(actorID:db.id,fullPlan:true,canApply:true,sessionID:session.id)
        let proposal = try PlanningActions.propose(.reserve(10000,"RUB"),db:db,explanation:"Fictional proposal",access:reader,session:session)
        let id = UUID(); XCTAssertThrowsError(try PlanningActions.apply(proposal,requestID:id,access:reader,session:session,in:&db)); XCTAssertEqual(db.planningData.reserve,0)
        let result = try PlanningActions.apply(proposal,requestID:id,access:writer,session:session,in:&db); XCTAssertEqual(try PlanningActions.apply(proposal,requestID:id,access:writer,session:session,in:&db),result); XCTAssertEqual(db.planningData.audit.count,1)
        var changed = proposal; changed.command = .reserve(20000,"RUB"); XCTAssertThrowsError(try PlanningActions.apply(changed,requestID:id,access:writer,session:session,in:&db))
        db.revision = 1; XCTAssertThrowsError(try PlanningActions.apply(proposal,requestID:UUID(),access:writer,session:session,in:&db)); session.revoke(); XCTAssertThrowsError(try PlanningActions.calculate(db:db,through:.today,access:reader,session:session))
    }
    func testProtectedFullBackupAndAtomicFailure() throws {
        var (db,_) = try fixture(); db.planningData.reserve = 12345; var goal = SavingsGoal(title:"Fictional house",target:100000,currency:"RUB",dueOn:.today.adding(30)); goal.allocated = 10000; db.planningData.goals = [goal]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = VaultStore(url:root.appendingPathComponent("vault.beesave")),key = try VaultCrypto.random(); let bootstrap = Bootstrap(databaseID:db.id,password:nil,recovery:Data())
        try store.initialize(db:db,dataKey:key,bootstrap:bootstrap); defer { store.close() }
        let snapshot = root.appendingPathComponent("copy.mubak"); try store.backup(to:snapshot); XCTAssertEqual(try VaultFile.read(Data(contentsOf:snapshot)).decrypt(key:key),db)
        let before = try Data(contentsOf:store.url); store.beforeWrite = { throw BudgetError.storage("Fictional storage failure") }; XCTAssertThrowsError(try store.transaction { $0.planningData.reserve = 555 }); XCTAssertEqual(try Data(contentsOf:store.url),before); XCTAssertEqual(store.db,db)
        XCTAssertFalse(String(decoding:before,as:UTF8.self).contains("Fictional house"))
    }
    func testDistributionAndReservationLimit() throws {
        XCTAssertEqual(try IncomeDistribution.calculate(netIncome:100000,rules:[IncomeAllocationRule(title:"Life",fixed:40000),IncomeAllocationRule(title:"Goal",percent:"20")]),[40000,20000])
        XCTAssertThrowsError(try IncomeDistribution.calculate(netIncome:100000,rules:[IncomeAllocationRule(title:"Too much",percent:"101")]))
        var (db,a) = try fixture(balance:1000); var goal = SavingsGoal(title:"A",target:1000,currency:"RUB",dueOn:.today); goal.accountID = a.id; goal.allocated = 600; try PlanningLedger.saveGoal(goal,in:&db); var second = goal; second.id = UUID(); XCTAssertThrowsError(try PlanningLedger.saveGoal(second,in:&db))
    }
}
