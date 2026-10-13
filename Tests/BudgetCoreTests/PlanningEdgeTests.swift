import XCTest
@testable import BudgetCore

final class PlanningEdgeTests: XCTestCase {
    func testOnlyLivingAllowanceCanCloseWithoutPaymentFact() throws {
        var db = Database(); var bill = PlanFlow(title:"Fictional obligation",purpose:.payment,amount:10000,currency:"RUB",start:.today)
        var exception = PlanException(anchor:.today); exception.closed = true; bill.exceptions = [exception]
        XCTAssertThrowsError(try PlanningLedger.saveFlow(bill,in:&db)); XCTAssertTrue(db.planningData.flows.isEmpty)
        var life = bill; life.purpose = .living; try PlanningLedger.saveFlow(life,in:&db)
        XCTAssertEqual(try PlanningEngine.occurrences(flow:life,db:db,from:.today,through:.today).first?.remaining,0); XCTAssertTrue(db.operations.isEmpty)
    }

    func testAcceptedMortgageAndEventPrioritiesStaySeparateFromFacts() throws {
        var db = Database(); var project = Project(name:"Fictional accepted mortgage"),details = ProjectDetails(),loan = ProjectLoan(); loan.principal = 100_000; loan.months = 12; loan.annualPercent = "12"; loan.firstPayment = .today.adding(5); details.type = .mortgage; details.stage = .active; details.loan = loan; project.details = details; try PlanningLedger.saveProject(project,in:&db)
        let events = try PlanningEngine.events(db:db,from:.today,through:.today.adding(30),financeEvents:[]); XCTAssertEqual(events.count,1); XCTAssertEqual(events.first?.certainty,.estimated); XCTAssertTrue(db.operations.isEmpty)
        db.planningData.eventSettings.priorityOverrides = ["payment":3]; let attention = try PlanningEvents.list(db:db,financeEvents:[]); XCTAssertEqual(attention.first?.priority,3)
        db.planningData.eventSettings.priorityOverrides = ["payment":4]; XCTAssertThrowsError(try PlanningLedger.validate(db))
    }

    func testOverdueDebtAndProjectCostsRemainInLiquidityAndIncompleteContractIsVisible() throws {
        var db = Database(); let own = Account(name:"Fictional own",currency:"RUB"); try Ledger.saveAccount(own,opening:100_000,in:&db)
        var loanAccount = Account(name:"Fictional loan",currency:"RUB"); loanAccount.financialKind = .termLoan; try Ledger.saveAccount(loanAccount,opening:-30_000,in:&db)
        let contract = FinancialContract(accountID:loanAccount.id,kind:.termLoan,start:.today.adding(-30),end:.today.adding(30),annualPercent:"12"); try FinancialLedger.saveContract(contract,in:&db)
        let event = FinanceEvent(id:"fictional.due",contractID:contract.id,kind:.loanPayment,date:.today.adding(-2),accrualEnd:.today.adding(-2),components:[FinancialAllocation(.principal,30_000)],amount:30_000,remaining:30_000,balanceAfter:0,accuracy:.incomplete,notes:["Fictional missing condition"])
        var d = ProjectDetails(); d.stage = .active; d.costs = [ProjectCost(title:"Fictional overdue cost",amount:20_000,dueOn:.today.adding(-1))]; var p = Project(name:"Fictional project"); p.details = d; try PlanningLedger.saveProject(p,in:&db)
        let projection = try PlanningEngine.projection(db:db,through:.today.adding(5),financeEvents:[event]); XCTAssertEqual(projection.ending,50_000); XCTAssertFalse(projection.complete); XCTAssertEqual(projection.points.count,2)
        let chart = try PlanningCharts.monthly(db:db,from:.today.firstOfMonth,through:.today.lastOfMonth,cash:true,forecast:projection.points.map(\.event)); XCTAssertEqual(chart.last?.expense,50_000); XCTAssertFalse(chart.last!.missing.isEmpty)
    }

    func testProjectDelayAndSavingsScenarioRetainsFactsAndOriginalPlan() throws {
        var db = Database(); let a = Account(name:"Fictional",currency:"RUB"); try Ledger.saveAccount(a,opening:100_000,in:&db)
        var d = ProjectDetails(); d.stage = .active; d.costs = [ProjectCost(title:"Fictional cost",amount:30_000,dueOn:.today.adding(2))]; var p = Project(name:"Fictional project"); p.details = d; try PlanningLedger.saveProject(p,in:&db)
        var goal = SavingsGoal(title:"Fictional savings",target:100_000,currency:"RUB",dueOn:.today.adding(100)); goal.monthly = 20_000; try PlanningLedger.saveGoal(goal,in:&db)
        let original = db; var scenario = PlanScenario(title:"Variant",snapshotRevision:0,flows:[],reserve:0,currency:"RUB"); scenario.projectDelayDays = 30; scenario.goalMonthlyPercent = 100
        let base = try PlanningEngine.projection(db:db,through:.today.adding(10),financeEvents:[]),variant = try PlanningEngine.scenario(scenario,db:db,through:.today.adding(10),financeEvents:[])
        XCTAssertEqual(base.ending,70_000); XCTAssertEqual(variant.ending,100_000); XCTAssertEqual(db,original); XCTAssertNotEqual(base.calculationID,variant.calculationID)
        scenario.projectDelayDays = 2000; XCTAssertThrowsError(try PlanningEngine.scenario(scenario,db:db,through:.today.adding(10),financeEvents:[]))
    }

    func testCurrentLivingPeriodAndIncludedLinesAreNotDoubleCounted() throws {
        var db = Database(); var parent = PlanFlow(title:"Fictional life",purpose:.living,amount:40000,currency:"RUB",start:.today.firstOfMonth)
        var child = PlanFlow(title:"Fictional internet",purpose:.payment,amount:10000,currency:"RUB",start:.today); child.parentFlowID = parent.id
        try PlanningLedger.saveFlow(parent,in:&db); try PlanningLedger.saveFlow(child,in:&db)
        let events = try PlanningEngine.events(db:db,from:.today,through:.today,financeEvents:[])
        XCTAssertEqual(events.reduce(Int64(0)) { $0 + ($1.remaining ?? 0) },40000)
        XCTAssertEqual(events.first { $0.sourceID == parent.id }?.remaining,30000)
        parent.amount = 5000; XCTAssertThrowsError(try PlanningLedger.saveFlow(parent,in:&db))
        var invalid = child; invalid.parentFlowID = child.id; XCTAssertThrowsError(try PlanningLedger.saveFlow(invalid,in:&db))
    }
    func testPastSeriesConditionsSurviveFutureEditsAndSameDayChanges() throws {
        var db = Database(); var flow = PlanFlow(title:"Fictional bill",purpose:.payment,amount:1000,currency:"RUB",start:.today.adding(-70)); try PlanningLedger.saveFlow(flow,in:&db)
        let old = try PlanningEngine.occurrences(flow:flow,db:db,from:flow.start,through:.today.adding(-1))
        flow.amount = 2000; try PlanningLedger.saveFlow(flow,in:&db); flow = db.planningData.flows[0]; flow.amount = 3000; try PlanningLedger.saveFlow(flow,in:&db)
        let actual = try PlanningEngine.occurrences(flow:db.planningData.flows[0],db:db,from:flow.start,through:.today.adding(-1))
        XCTAssertEqual(old,actual)
        XCTAssertEqual(try PlanningEngine.occurrences(flow:db.planningData.flows[0],db:db,from:.today,through:.today.adding(40)).first?.amount,3000)
        flow = db.planningData.flows[0]; flow.start = .today; XCTAssertThrowsError(try PlanningLedger.saveFlow(flow,in:&db))
    }
    func testActualSpendingCanBreachGoalReservation() throws {
        var db = Database(); let a = Account(name:"Fictional card",currency:"RUB"); try Ledger.saveAccount(a,opening:10000,in:&db)
        var goal = SavingsGoal(title:"Fictional reserve",target:20000,currency:"RUB",dueOn:.today.adding(60)); goal.allocated = 9000; goal.accountID = a.id; try PlanningLedger.saveGoal(goal,in:&db)
        var op = BudgetCore.Operation(kind:.expense,accountID:a.id,amount:5000); op.categoryID = db.categories[0].id; try Ledger.saveOperation(op,in:&db)
        XCTAssertNoThrow(try Ledger.validate(db)); XCTAssertEqual(try db.balance(a.id),5000)
        let p = try PlanningEngine.projection(db:db,through:.today,financeEvents:[]); XCTAssertEqual(try p.freeEnding,-4000)
    }
    func testExternalPartnerPaymentSettlesInvoiceAndReimbursementDoesNotRepeatCost() throws {
        var db = Database(); let a = Account(name:"Fictional own card",currency:"RUB"); try Ledger.saveAccount(a,opening:100000,in:&db)
        var project = Project(name:"Fictional renovation"),details = ProjectDetails(); details.stage = .active
        let party = ProjectParticipant(name:"Fictional partner"); details.participants = [party]
        let invoice = ScheduledPayment(title:"Fictional contractor",comment:"Fictional contract",amount:10000,currency:"RUB",dueOn:.today); try ScheduledPayments.save(invoice,in:&db)
        var cost = ProjectCost(title:"Fictional work",amount:10000,dueOn:.today); cost.scheduledPaymentID = invoice.id; cost.contracted = true; details.costs = [cost]
        var fact = ProjectFact(date:.today,amount:10000); fact.participantID = party.id; fact.costID = cost.id; fact.confirmed = true; details.facts = [fact]; project.details = details; try PlanningLedger.saveProject(project,in:&db)
        XCTAssertEqual(try ScheduledPayments.remaining(invoice,db:db),0); XCTAssertEqual(try db.balance(a.id),100000)
        let repay = ScheduledPayment(title:"Fictional reimbursement",comment:"Repay partner",amount:10000,currency:"RUB",dueOn:.today); try ScheduledPayments.save(repay,in:&db)
        project = db.projects[0]; project.details!.facts[0].reimbursementPaymentID = repay.id; try PlanningLedger.saveProject(project,in:&db)
        var op = BudgetCore.Operation(kind:.expense,accountID:a.id,amount:10000); op.categoryID = db.categories[0].id; op.projectID = project.id; try Ledger.saveOperation(op,in:&db)
        db.finances!.scheduledPayments![1].allocations = [ScheduledPaymentAllocation(operationID:op.id,sourceAmount:10000,amount:10000,sourceCurrency:"RUB")]
        let summary = try ProjectEngine.summary(project:db.projects[0],db:db); XCTAssertEqual(summary.forecast,10000); XCTAssertEqual(summary.paid,10000); XCTAssertEqual(summary.userPaid,10000)
    }
    func testMortgageRateChangesManualGraphAndFullEarlyClosure() throws {
        var loan = ProjectLoan(); loan.principal = 1000000; loan.months = 12; loan.annualPercent = "12"; loan.firstPayment = .today.adding(31)
        let original = try ProjectEngine.loanSchedule(loan)
        loan.rateChanges = [ProjectLoanRate(date:try FinanceMath.addingMonths(loan.firstPayment,3),annualPercent:"24")]
        let revised = try ProjectEngine.loanSchedule(loan); XCTAssertEqual(revised.last?.remaining,0); XCTAssertGreaterThan(revised.reduce(Int64(0)) { $0+$1.interest },original.reduce(Int64(0)) { $0+$1.interest })
        let early = .today.adding(15) as Day
        let paid = try ProjectEngine.loanSchedule(loan,prepayments:[ProjectPrepayment(date:early,amount:loan.principal,mode:.reduceTerm)]); XCTAssertEqual(paid.last?.date,early); XCTAssertEqual(paid.last?.remaining,0)
        loan.manual = [ProjectLoanRow(date:loan.firstPayment,principal:loan.principal,interest:5000,remaining:0)]
        XCTAssertEqual(try ProjectEngine.loanSchedule(loan),loan.manual)
        XCTAssertThrowsError(try ProjectEngine.loanSchedule(loan,prepayments:[ProjectPrepayment(date:early,amount:100,mode:.reducePayment)]))
        loan.manual[0].remaining = 1; XCTAssertThrowsError(try ProjectEngine.loanSchedule(loan))
    }
    func testLowerPaymentOnFirstDueDateKeepsEarnedInterestAndOriginalTerm() throws {
        var loan = ProjectLoan(); loan.principal = 1_000_000_000; loan.months = 240; loan.annualPercent = "12"; loan.firstPayment = .today.adding(30)
        let original = try ProjectEngine.loanSchedule(loan)
        let changed = try ProjectEngine.loanSchedule(loan,prepayments:[ProjectPrepayment(date:loan.firstPayment,amount:100_000_000,mode:.reducePayment)])
        XCTAssertEqual(changed.last?.remaining,0); XCTAssertEqual(changed.last?.date,original.last?.date)
        XCTAssertEqual(changed.first?.interest,original.first?.interest)
        XCTAssertLessThan(try changed[1].payment,try original[1].payment)
    }
    func testUnknownTaxNeverMakesCompleteFundingPlan() throws {
        var db = Database(),tax = TaxProfile(); tax.country = "OTHER"; tax.expectedOn = .today.adding(2); db.planningData.taxes = [tax]
        let p = try PlanningEngine.projection(db:db,through:.today.adding(3),financeEvents:[],opening:100000)
        XCTAssertFalse(p.complete); XCTAssertTrue(p.missing.contains { $0.contains("НДФЛ") })
        let rows = try PlanningEngine.events(db:db,from:.today,through:.today.adding(3),financeEvents:[]); XCTAssertNil(rows.first?.remaining)
    }
}
