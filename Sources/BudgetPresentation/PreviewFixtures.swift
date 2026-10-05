import Foundation
import BudgetCore

public enum PreviewScenario: String, CaseIterable, Sendable {
    case new, empty, account, filled, partial, archived, custom, volume
    public var title: String { switch self { case .new: "Первый запуск"; case .empty: "Нет счетов"; case .account: "Счёт без потоков"; case .filled: "Заполненная Главная"; case .partial: "Нет курса"; case .archived: "Архив"; case .custom: "Своя раскладка"; case .volume: "100 000 операций" } }
}
public enum PreviewFixtures {
    public static func database(_ scenario: PreviewScenario, today: Day = .today) throws -> Database {
        if scenario == .volume { return try volume(today: today) }
        var db = Database(); db.settings.dashboardFilters = Filters(start: today.firstOfMonth, end: today); db.settings.lastRateCheck = Date(); db.settings.lockMinutes = 0
        if scenario == .empty || scenario == .new { return db }
        var main = Account(name: "Основной счёт", currency: "RUB", openedOn: today.firstOfMonth); main.id = UUID(uuidString: "00200000-0000-0000-0000-000000000001")!
        try Ledger.saveAccount(main, opening: 420_000, in: &db)
        if scenario == .account { return db }
        var cash = Account(name: "Наличные", currency: "RUB", openedOn: main.openedOn); cash.id = UUID(uuidString: "00200000-0000-0000-0000-000000000002")!
        var usd = Account(name: "Доллары", currency: "USD", openedOn: main.openedOn); usd.id = UUID(uuidString: "00200000-0000-0000-0000-000000000003")!
        try Ledger.saveAccount(cash, opening: 185_000, in: &db); try Ledger.saveAccount(usd, opening: 20_000, in: &db)
        let food = BudgetCore.Category(name: "Продукты", kind: .expense); try Ledger.saveCategory(food, in: &db)
        let child = BudgetCore.Category(name: "Супермаркет", kind: .expense, parentID: food.id); try Ledger.saveCategory(child, in: &db)
        let transport = BudgetCore.Category(name: "Транспорт", kind: .expense); try Ledger.saveCategory(transport, in: &db)
        let project = Project(name: "Ремонт кухни"); try Ledger.saveProject(project, in: &db)
        var expense = Operation(kind: .expense, date: today, accountID: main.id, amount: 110_000); expense.categoryID = child.id; expense.projectID = project.id; expense.comment = "Покупки для дома"; try Ledger.saveOperation(expense, in: &db)
        var ride = Operation(kind: .expense, date: today.firstOfMonth, accountID: main.id, amount: 18_000); ride.categoryID = transport.id; ride.comment = "Проезд"; try Ledger.saveOperation(ride, in: &db)
        var salary = Operation(kind: .income, date: today, accountID: main.id, amount: 3_000_000); salary.comment = "Зарплата"; try Ledger.saveOperation(salary, in: &db)
        var monthly = Budget(kind: .monthly, name: "План на месяц", currency: "RUB", start: today.firstOfMonth); monthly.lines = [BudgetLine(categoryID: food.id, limit: 300_000), BudgetLine(categoryID: transport.id, limit: 150_000)]; try Ledger.saveBudget(monthly, in: &db)
        var plan = Budget(kind: .project, name: "Кухня", currency: "RUB", start: today.firstOfMonth); plan.projectID = project.id; plan.limit = 100_000; try Ledger.saveBudget(plan, in: &db)
        if scenario == .partial { var dollar = Operation(kind: .expense, date: today, accountID: usd.id, amount: 2_500); dollar.comment = "Расход без снимка курса"; try Ledger.saveOperation(dollar, in: &db) }
        else { db.rates = [FXRate(base: "USD", quote: "RUB", rate: "92", date: today)] }
        if scenario == .archived { var archived = Account(name: "Старый счёт", currency: "RUB", openedOn: today.firstOfMonth); try Ledger.saveAccount(archived, opening: -5_000, in: &db); archived.archived = true; try Ledger.saveAccount(archived, in: &db) }
        if scenario == .custom { var own = Filters(start: today.firstOfMonth, end: today); own.accounts = [cash.id]; var balances = DashboardBlock(kind: "balances"); balances.wide = true; balances.ownFilters = own; var hidden = DashboardBlock(kind: "trend"); hidden.visible = false; db.dashboard = [DashboardBlock(kind: "categories"), balances, hidden, DashboardBlock(kind: "flows")] }
        try Ledger.validate(db); return db
    }
    private static func volume(today: Day) throws -> Database {
        var db = Database(); db.settings.lockMinutes = 0; db.settings.lastRateCheck = Date(); db.settings.dashboardFilters = Filters(start: today.firstOfMonth, end: today)
        db.accounts = (0..<100).map { Account(name: "Счёт \($0)", currency: "RUB", openedOn: today.firstOfMonth) }
        db.categories += (0..<498).map { BudgetCore.Category(name: "Категория \($0)", kind: .expense) }
        db.projects = (0..<100).map { Project(name: "Проект \($0)") }
        db.reports = (0..<100).map { Report(name: "Отчёт \($0)") }
        var monthly = Budget(kind: .monthly, name: "Месяц", currency: "RUB", start: today.firstOfMonth); monthly.lines = [BudgetLine(categoryID: db.categories[2].id, limit: 10_000_000)]
        var project = Budget(kind: .project, name: "Проект", currency: "RUB", start: today.firstOfMonth); project.projectID = db.projects[0].id; project.limit = 10_000_000; db.budgets = [monthly, project]
        db.operations.reserveCapacity(100_000)
        for index in 0..<100_000 { var operation = Operation(kind: index % 5 == 0 ? .income : .expense, date: today, accountID: db.accounts[index % 100].id, amount: Int64(1 + index % 10_000)); operation.categoryID = operation.kind == .income ? db.categories[1].id : db.categories[2 + index % 498].id; operation.projectID = db.projects[index % 100].id; operation.comment = "Тест \(index)"; db.operations.append(operation) }
        try Ledger.validate(db); return db
    }
}
