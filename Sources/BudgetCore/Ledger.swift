import Foundation

public enum Ledger {
    public static func normalized(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive], locale: Locale(identifier: "ru_RU")) }
    public static func nonempty(_ name: String) throws { guard !normalized(name).isEmpty else { throw BudgetError.invalid("Название не может быть пустым.") } }
    public static func saveAccount(_ account: Account, opening: Int64? = nil, in db: inout Database) throws {
        var a = account; a.name = a.name.trimmingCharacters(in: .whitespacesAndNewlines); try nonempty(a.name); _ = try Currency.get(a.currency)
        guard a.openedOn <= .today else { throw BudgetError.invalid("Дата открытия не может быть в будущем.") }
        guard !db.accounts.contains(where: { $0.id != a.id && normalized($0.name) == normalized(a.name) }) else { throw BudgetError.conflict("Счёт с таким названием уже существует.") }
        let records = db.operations.filter { $0.accountID == a.id || $0.toAccountID == a.id }
        if let old = db.accounts.first(where: { $0.id == a.id }), old.kind != a.kind, !records.isEmpty { throw BudgetError.conflict("Настройте финансовый договор отдельной командой; тип счёта с историей не меняется напрямую.") }
        if let old = db.accounts.first(where: { $0.id == a.id }), old.currency != a.currency, !records.isEmpty { throw BudgetError.conflict("Валюта счёта с историей не меняется. Создайте другой счёт.") }
        guard records.allSatisfy({ $0.date >= a.openedOn }) else { throw BudgetError.invalid("Дата открытия позже имеющихся операций.") }
        a.modifiedAt = Date()
        if let i = db.accounts.firstIndex(where: { $0.id == a.id }) { db.accounts[i] = a }
        else { db.accounts.append(a); if let opening, opening != 0 { db.operations.append(Operation(kind: .opening, date: a.openedOn, accountID: a.id, amount: opening)) } }
    }
    public static func deleteAccount(_ id: UUID, in db: inout Database) throws {
        guard db.contract(for: id) == nil, db.financeData.contracts.allSatisfy({ contract in contract.paymentAccountID != id && contract.terms.allSatisfy { $0.deposit.payoutAccountID != id && $0.loan.escrowAccountID != id } }) else { throw BudgetError.conflict("Счёт используется в финансовом договоре. Архивируйте его.") }
        guard !db.operations.contains(where: { $0.accountID == id || $0.toAccountID == id }), !db.reports.contains(where: { $0.filters.accounts.contains(id) }), !db.dashboard.contains(where: { $0.ownFilters?.accounts.contains(id) == true }), !db.settings.dashboardFilters.accounts.contains(id) else { throw BudgetError.conflict("Счёт используется в истории или фильтрах. Архивируйте его.") }
        db.accounts.removeAll { $0.id == id }
    }
    public static func saveCategory(_ category: Category, in db: inout Database) throws {
        var c = category; c.name = c.name.trimmingCharacters(in: .whitespacesAndNewlines); try nonempty(c.name)
        guard c.kind.isFlow else { throw BudgetError.invalid("Тип категории — расход или доход.") }
        if let parent = c.parentID {
            guard let p = db.categories.first(where: { $0.id == parent }), p.parentID == nil, p.kind == c.kind, p.id != c.id, !p.archived else { throw BudgetError.invalid("Родитель должен быть активной категорией первого уровня того же типа.") }
            guard !db.categories.contains(where: { $0.parentID == c.id }) else { throw BudgetError.conflict("Подкатегория не может иметь собственных подкатегорий.") }
        }
        guard !db.categories.contains(where: { $0.id != c.id && $0.parentID == c.parentID && $0.kind == c.kind && normalized($0.name) == normalized(c.name) }) else { throw BudgetError.conflict("Название категории уже занято на этом уровне.") }
        if let i = db.categories.firstIndex(where: { $0.id == c.id }) {
            let old = db.categories[i]
            guard !old.system || c == old else { throw BudgetError.conflict("Системную категорию изменить нельзя.") }
            if categoryUsed(c.id, db: db) && (old.kind != c.kind || old.parentID != c.parentID) { throw BudgetError.conflict("Использованную категорию нельзя переместить или сменить её тип.") }
            db.categories[i] = c
        } else { db.categories.append(c) }
    }
    public static func categoryUsed(_ id: UUID, db: Database) -> Bool {
        db.operations.contains { $0.categoryID == id } || db.budgets.contains { $0.lines.contains { $0.categoryID == id } } || db.reports.contains { $0.filters.categories.contains(id) } || db.dashboard.contains { $0.ownFilters?.categories.contains(id) == true } || db.settings.dashboardFilters.categories.contains(id)
    }
    public static func deleteCategory(_ id: UUID, in db: inout Database) throws {
        guard let c = db.categories.first(where: { $0.id == id }), !c.system, !categoryUsed(id, db: db), !db.categories.contains(where: { $0.parentID == id }) else { throw BudgetError.conflict("Категория используется или является системной. Доступно архивирование использованных категорий.") }
        db.categories.removeAll { $0.id == id }
    }
    public static func saveProject(_ project: Project, in db: inout Database) throws {
        var p = project; p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines); try nonempty(p.name)
        guard !db.projects.contains(where: { $0.id != p.id && normalized($0.name) == normalized(p.name) }) else { throw BudgetError.conflict("Проект с таким названием уже существует.") }
        if let i = db.projects.firstIndex(where: { $0.id == p.id }) { db.projects[i] = p } else { db.projects.append(p) }
    }
    public static func deleteProject(_ id: UUID, in db: inout Database) throws {
        guard !db.operations.contains(where: { $0.projectID == id }), !db.budgets.contains(where: { $0.projectID == id }), !db.reports.contains(where: { $0.filters.projectID == id }), !db.dashboard.contains(where: { $0.ownFilters?.projectID == id }), db.settings.dashboardFilters.projectID != id else { throw BudgetError.conflict("Проект используется. Архивируйте его.") }
        db.projects.removeAll { $0.id == id }
    }
    public static func saveOperation(_ operation: Operation, currencyConfirmed: Bool = false, in db: inout Database) throws {
        var o = operation; let source = try db.account(o.accountID)
        guard !source.archived else { throw BudgetError.invalid("Для изменения финансовых полей верните счёт из архива.") }
        if let id = o.toAccountID, try db.account(id).archived { throw BudgetError.invalid("Счёт получателя архивирован.") }
        if let old = db.operations.first(where: { $0.id == o.id }) {
            guard old.financial?.groupID == nil else { throw BudgetError.conflict("Изменение относится ко всей финансовой группе. Удалите её и подтвердите исправленный платёж.") }
            guard !(try db.account(old.accountID).archived), old.toAccountID.map({ id in db.accounts.first { $0.id == id }?.archived ?? true }) != true else { throw BudgetError.invalid("Верните затронутые счета из архива.") }
            if try db.account(old.accountID).currency != source.currency, !currencyConfirmed { throw BudgetError.invalid("Подтвердите сумму в новой валюте; обновите курсовые снимки.") }
            if old.kind == .adjustment || old.kind == .opening { throw BudgetError.invalid("Корректировку исправляют удалением и новой сверкой. Начальный остаток задаётся при создании счёта.") }
            o.createdAt = old.createdAt
        }
        if o.kind.isFlow, o.categoryID == nil { o.categoryID = db.categories.first(where: { $0.system && $0.kind == o.kind })?.id }
        if let c = db.categories.first(where: { $0.id == o.categoryID }), c.archived || c.parentID.flatMap({ id in db.categories.first { $0.id == id } })?.archived == true { throw BudgetError.invalid("Архивная категория недоступна для новых/изменённых операций.") }
        if let p = db.projects.first(where: { $0.id == o.projectID }), p.archived { throw BudgetError.invalid("Проект архивирован.") }
        if o.kind == .transfer, let to = o.toAccountID, let received = o.toAmount {
            o.transferRate = try Money.ratio(from: o.amount, currency: source.currency, to: received, toCurrency: db.account(to).currency)
        }
        o.modifiedAt = Date(); try validateOperation(o, accounts: Dictionary(uniqueKeysWithValues: db.accounts.map { ($0.id, $0) }), categories: Dictionary(uniqueKeysWithValues: db.categories.map { ($0.id, $0) }), projects: Set(db.projects.map(\.id)))
        let warnings = try FinancialLedger.depositWarnings(o, db: db)
        if !warnings.isEmpty && o.financial?.contractViolationConfirmed != true { throw BudgetError.invalid(warnings.joined(separator: " ") + " Подтвердите фактическую операцию и укажите последствия.") }
        if let i = db.operations.firstIndex(where: { $0.id == o.id }) { db.operations[i] = o } else { db.operations.append(o) }
        _ = try db.balance(o.accountID); if let to = o.toAccountID { _ = try db.balance(to) }
    }
    public static func reconcile(accountID: UUID, observed: Int64, reason: String, in db: inout Database) throws -> Operation? {
        try nonempty(reason); let balance = try db.balance(accountID); let (delta, overflow) = observed.subtractingReportingOverflow(balance); guard !overflow else { throw BudgetError.overflow }; guard delta != 0 else { return nil }
        var o = Operation(kind: .adjustment, accountID: accountID, amount: delta); o.comment = reason; o.observedBalance = observed
        try saveOperation(o, in: &db); return o
    }
    public static func deleteOperation(_ id: UUID, in db: inout Database) throws {
        guard let o = db.operations.first(where: { $0.id == id }) else { return }
        if let groupID = o.financial?.groupID { try FinancialLedger.deleteGroup(groupID, in: &db); return }
        guard !(try db.account(o.accountID).archived), o.toAccountID.flatMap({ to in db.accounts.first { $0.id == to } })?.archived != true else { throw BudgetError.invalid("Для удаления верните счета из архива.") }
        db.operations.removeAll { $0.id == id }
        db.finances?.fulfillments.removeAll { $0.operationIDs.contains(id) }
    }
    public static func validateOperation(_ o: Operation, accounts: [UUID: Account], categories: [UUID: Category], projects: Set<UUID>, today: Day = .today) throws {
        guard let a = accounts[o.accountID], o.date >= a.openedOn, o.date <= today else { throw BudgetError.invalid("Операция раньше открытия счёта или в будущем.") }
        if o.kind.isFlow || o.kind == .transfer { guard o.amount > 0 else { throw BudgetError.invalid("Сумма должна быть положительной.") } }
        if o.kind.isFlow { guard let id = o.categoryID, let c = categories[id], c.kind == o.kind else { throw BudgetError.invalid("Нужна категория соответствующего типа.") } }
        else { guard o.categoryID == nil, o.projectID == nil else { throw BudgetError.invalid("Категория и проект допустимы только для доходов/расходов.") } }
        if let id = o.projectID { guard projects.contains(id) else { throw BudgetError.invalid("Проект не найден.") } }
        if o.kind == .transfer {
            guard let to = o.toAccountID, let b = accounts[to], to != a.id, let received = o.toAmount, received > 0, o.date >= b.openedOn else { throw BudgetError.invalid("Перевод требует разные счета и две положительные суммы.") }
            if a.currency == b.currency { guard received == o.amount, o.transferRate == "1" else { throw BudgetError.invalid("Перевод одной валюты требует равных сумм и курса 1.") } }
            guard let rate = o.transferRate, try Money.decimal(rate) > 0 else { throw BudgetError.invalid("Не указан курс перевода.") }
            let truth = try Money.ratio(from: o.amount, currency: a.currency, to: received, toCurrency: b.currency)
            guard try Money.decimal(rate) == Money.decimal(truth) else { throw BudgetError.invalid("Курс перевода не соответствует фактическим суммам.") }
        } else { guard o.toAccountID == nil, o.toAmount == nil, o.transferRate == nil else { throw BudgetError.invalid("Лишние поля получателя.") } }
        if o.kind == .adjustment { guard o.amount != 0, !o.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BudgetError.invalid("Корректировка требует ненулевую разницу и причину.") } }
        for rate in o.fx { try validateRate(rate); guard rate.date <= o.date else { throw BudgetError.invalid("Курс снимка не может быть позже операции.") } }
    }
    public static func validateRate(_ r: FXRate) throws {
        _ = try Currency.get(r.base); _ = try Currency.get(r.quote)
        guard try Money.decimal(r.rate) > 0, r.date <= .today, r.base != r.quote, !r.provider.isEmpty else { throw BudgetError.invalid("Некорректная валютная пара, курс или дата.") }
    }
    public static func categoryContains(_ parent: UUID, _ child: UUID?, db: Database) -> Bool { child == parent || db.categories.first(where: { $0.id == child })?.parentID == parent }
    public static func matches(_ o: Operation, budget: Budget, db: Database) -> Bool {
        guard o.kind == .expense, o.budgetMode == .automatic, o.date >= budget.start, budget.endDate == nil || o.date <= budget.endDate! else { return false }
        return budget.kind == .project ? o.projectID == budget.projectID : budget.lines.contains { categoryContains($0.categoryID, o.categoryID, db: db) }
    }
    public static func saveBudget(_ budget: Budget, in db: inout Database) throws {
        try validateBudget(budget, db: db)
        if let old = db.budgets.first(where: { $0.id == budget.id }), old.currency != budget.currency, db.operations.contains(where: { matches($0, budget: old, db: db) }) { throw BudgetError.conflict("Валюту бюджета с учтёнными расходами изменить нельзя.") }
        if let i = db.budgets.firstIndex(where: { $0.id == budget.id }) { db.budgets[i] = budget } else { db.budgets.append(budget) }
    }
    public static func validateBudget(_ b: Budget, db: Database) throws {
        try nonempty(b.name); _ = try Currency.get(b.currency)
        if b.kind == .monthly {
            guard b.start == b.start.firstOfMonth, !b.lines.isEmpty, b.projectID == nil else { throw BudgetError.invalid("Месячный бюджет требует месяц и строки категорий.") }
            guard !db.budgets.contains(where: { $0.id != b.id && $0.kind == .monthly && $0.start.month == b.start.month }) else { throw BudgetError.conflict("На этот месяц уже есть план.") }
            var seen = Set<UUID>()
            for line in b.lines {
                guard line.limit >= 0, let c = db.categories.first(where: { $0.id == line.categoryID }), c.kind == .expense, seen.insert(c.id).inserted else { throw BudgetError.invalid("Строки требуют уникальные категории расходов и неотрицательные лимиты.") }
                for other in b.lines where other.id != line.id { guard !categoryContains(other.categoryID, c.id, db: db) else { throw BudgetError.conflict("Строки родителя и подкатегории пересекаются.") } }
            }
        } else {
            guard b.limit > 0, let project = b.projectID, db.projects.contains(where: { $0.id == project }), b.end == nil || b.end! >= b.start, !b.completed || b.end != nil else { throw BudgetError.invalid("Бюджет проекта требует проект, положительный лимит и корректный интервал.") }
            for other in db.budgets where other.id != b.id && other.kind == .project && other.projectID == project {
                let far = try Day("9999-12-31")
                guard (b.end ?? far) < other.start || (other.end ?? far) < b.start else { throw BudgetError.conflict("Интервал пересекается с бюджетом «\(other.name)».") }
            }
        }
        _ = try b.plan
    }
    public static func validate(_ db: Database) throws {
        let today = Day.today
        guard db.version <= 2 else { throw BudgetError.newerVersion }; guard db.version == 1 || db.version == 2 else { throw BudgetError.corrupt }
        if db.version == 1 { guard db.finances == nil, db.accounts.allSatisfy({ $0.kind == .ordinary }), db.operations.allSatisfy({ $0.financial == nil }) else { throw BudgetError.corrupt } }
        func unique<T>(_ values: [T], id: (T) -> UUID) throws { guard Set(values.map(id)).count == values.count else { throw BudgetError.corrupt } }
        try unique(db.accounts, id: \.id); try unique(db.categories, id: \.id); try unique(db.projects, id: \.id); try unique(db.operations, id: \.id); try unique(db.budgets, id: \.id); try unique(db.reports, id: \.id)
        var names = Set<String>()
        for a in db.accounts { try nonempty(a.name); _ = try Currency.get(a.currency); guard names.insert(normalized(a.name)).inserted, a.openedOn <= .today else { throw BudgetError.corrupt } }
        names.removeAll()
        for p in db.projects { try nonempty(p.name); guard names.insert(normalized(p.name)).inserted else { throw BudgetError.corrupt } }
        let cats = Dictionary(uniqueKeysWithValues: db.categories.map { ($0.id, $0) }); names.removeAll()
        for c in db.categories {
            try nonempty(c.name); guard c.kind.isFlow, names.insert(c.kind.rawValue + (c.parentID?.uuidString ?? "") + normalized(c.name)).inserted else { throw BudgetError.corrupt }
            if let p = c.parentID { guard let parent = cats[p], parent.parentID == nil, parent.kind == c.kind, p != c.id else { throw BudgetError.corrupt } }
        }
        for kind in [OperationKind.expense, .income] { guard db.categories.filter({ $0.kind == kind && $0.system && !$0.archived && $0.parentID == nil && $0.name == "Без категории" }).count == 1 else { throw BudgetError.corrupt } }
        let accounts = Dictionary(uniqueKeysWithValues: db.accounts.map { ($0.id, $0) }); let projects = Set(db.projects.map(\.id)); var balances: [UUID: Int64] = [:]; var openings = Set<UUID>()
        for o in db.operations {
            try validateOperation(o, accounts: accounts, categories: cats, projects: projects, today: today)
            if o.kind == .opening { guard openings.insert(o.accountID).inserted else { throw BudgetError.invalid("У счёта несколько начальных остатков.") } }
            balances[o.accountID] = try Money.add(balances[o.accountID] ?? 0, o.posting(for: o.accountID))
            if let to = o.toAccountID { balances[to] = try Money.add(balances[to] ?? 0, o.posting(for: to)) }
        }
        for b in db.budgets { try validateBudget(b, db: db) }
        for r in db.rates { try validateRate(r) }
        for r in db.reports { try Reports.validate(r, db: db) }
        _ = try Currency.get(db.settings.baseCurrency); _ = try Currency.get(db.settings.reportCurrency)
        for block in db.dashboard { if let id = block.reportID { guard db.reports.contains(where: { $0.id == id }) else { throw BudgetError.corrupt } }; if let f = block.ownFilters { try Reports.validateFilters(f, db: db) } }
        try Reports.validateFilters(db.settings.dashboardFilters, db: db)
        try FinancialLedger.validate(db)
    }
}
