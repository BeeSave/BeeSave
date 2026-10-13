#if DEBUG && UI_SMOKE
import Foundation
import BudgetCore

/// Fictional scenario only, excluded from Release compilation.
enum PlanningQAFixture {
    static func database() throws -> Database {
        var db = Database(); db.settings.lastDaily = .today; db.planningData.reserve = 5_000_000
        let a = Account(name:"Основная карта · вымышленные данные",currency:"RUB",openedOn:.today.adding(-200))
        try Ledger.saveAccount(a,opening:20_000_000,in:&db)
        let usd = Account(name:"Долларовые накопления",currency:"USD",openedOn:.today.adding(-200)); try Ledger.saveAccount(usd,opening:200_000,in:&db)
        let rate = FXRate(base:"USD",quote:"RUB",rate:"90",date:.today,provider:"Вымышленный курс QA"); db.rates = [rate]; db.planningData.forecastRates = [rate]
        for index in 0..<6 {
            let date = try FinanceMath.addingMonths(Day.today.firstOfMonth,-index)
            var income = Operation(kind:.income,date:date,accountID:a.id,amount:18_000_000 + Int64(index)*100_000); income.categoryID = db.categories[1].id; income.comment = "Вымышленная зарплата"; try Ledger.saveOperation(income,in:&db)
            var expense = Operation(kind:.expense,date:date,accountID:a.id,amount:7_000_000 + Int64(index)*200_000); expense.categoryID = db.categories[0].id; expense.comment = "Вымышленная стоимость жизни"; try Ledger.saveOperation(expense,in:&db)
        }
        let start = .today as Day
        for (name,purpose,amount,offset) in [("Зарплата после НДФЛ",PlanPurpose.income,18_000_000,12),("Жизнь: продукты, кафе и бензин",.living,7_000_000,3),("ЖКХ и интернет",.payment,1_500_000,2)] {
            var flow = PlanFlow(title:name,purpose:purpose,amount:Int64(amount),currency:"RUB",start:start.adding(offset)); flow.accountID = a.id; try PlanningLedger.saveFlow(flow,in:&db)
        }
        let insurance = ScheduledPayment(title:"КАСКО · второй платёж",comment:"Вымышленная рассрочка",amount:6_000_000,currency:"RUB",dueOn:start.adding(4)); try ScheduledPayments.save(insurance,in:&db)
        let overdue = ScheduledPayment(title:"Обязательный платёж · вымышленный",comment:"QA просрочки",amount:500_000,currency:"RUB",dueOn:start.adding(-2)); try ScheduledPayments.save(overdue,in:&db)
        var goal = SavingsGoal(title:"Первоначальный взнос",target:150_000_000,currency:"RUB",dueOn:start.adding(730)); goal.allocated = 10_000_000; goal.monthly = 5_000_000; goal.accountID = a.id; try PlanningLedger.saveGoal(goal,in:&db)
        var project = Project(name:"Ремонт квартиры"); var d = ProjectDetails(); d.type = .renovation; d.stage = .active; d.currency = "RUB"; d.target = 100_000_000; d.reserve = 10_000_000
        var user = ProjectParticipant(name:"Я"); user.isUser = true; user.promised = 60_000_000; user.incomePercent = "60"
        var party = ProjectParticipant(name:"Соучастник · вымышленный"); party.promised = 40_000_000; party.incomePercent = "40"; d.participants = [user,party]
        var c = ProjectCost(title:"Договор на первый этап",amount:70_000_000,dueOn:start.adding(30)); c.contracted = true; c.participantID = user.id; d.costs = [c,ProjectCost(title:"Материалы и оставшиеся работы",amount:20_000_000,dueOn:start.adding(60))]
        var fact = ProjectFact(date:.today,amount:30_000_000); fact.costID = c.id; fact.participantID = party.id; fact.confirmed = true; d.facts = [fact]; project.details = d; try PlanningLedger.saveProject(project,in:&db)
        var home = Project(name:"Ипотека: сравнение вариантов"), loan = ProjectLoan(); loan.principal = 1_000_000_000; loan.annualPercent = "12"; loan.months = 240; loan.firstPayment = start.adding(30); var hd = ProjectDetails(); hd.type = .mortgage; hd.stage = .planning; hd.loan = loan; home.details = hd; try PlanningLedger.saveProject(home,in:&db)
        var cafe = Project(name:"Кофейня: план запуска"), business = BusinessModel(); business.initial = 120_000_000; business.revenue = 30_000_000; business.fixed = 12_000_000; business.variable = 10_000_000; business.tax = 1_500_000; var bd = ProjectDetails(); bd.type = .business; bd.business = business; cafe.details = bd; try PlanningLedger.saveProject(cafe,in:&db)
        let deposit = Account(name:"Вклад: решение о продлении",currency:"RUB",openedOn:.today.adding(-90)); try Ledger.saveAccount(deposit,opening:10_000_000,in:&db)
        var contract = FinancialContract(accountID:deposit.id,kind:.deposit,start:.today.adding(-90),end:.today.adding(10),annualPercent:"12"); contract.originalPrincipal = 10_000_000; contract.terms[0].deposit.payoutAccountID = a.id; try FinancialLedger.saveContract(contract,in:&db)
        var tax = TaxProfile(); tax.title = "НДФЛ и вычеты: квартира"; tax.grossEmployment = 300_000_000; tax.withheld = 40_200_000; tax.housingEligible = true; tax.housingCost = 200_000_000; db.planningData.taxes = [tax]; db.planningData.taxResults = [try CountryModules.calculate(tax,revision:0)]
        try Ledger.validate(db); return db
    }
}
#endif

#if DEBUG && UI_SMOKE
extension AppModel {
    func preparePlanningAccountVolumeQA() {
        guard root.lastPathComponent.hasPrefix("BeeSaveSmoke-") else { return }
        do { try commit { db in
            for i in db.accounts.count..<100 { let account = Account(name:"Вымышленный счёт \(i) · длинное название накопления на важную цель",currency:i % 3 == 0 ? "USD" : "RUB"); try Ledger.saveAccount(account,opening:Int64(i+1)*100000,in:&db) }
        }; historyAccount = nil; section = .accounts } catch { self.error = error.localizedDescription }
    }
    func preparePlanning019QA() {
        guard root.lastPathComponent.hasPrefix("BeeSaveSmoke-") else { return }
        do { try commit { db in let identity = db.id; db = try PlanningQAFixture.database(); db.id = identity }; planningProjectID = nil; section = .dashboard }
        catch { self.error = error.localizedDescription }
    }
}
#endif
