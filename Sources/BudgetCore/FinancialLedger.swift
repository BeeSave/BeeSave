import Foundation

public struct CreditLotBalance: Equatable, Sendable {
    public var id: UUID; public var date: Day; public var kind: CreditTransactionKind; public var amount: Int64
}
public struct CreditExposurePoint: Equatable, Sendable {
    public var date: Day; public var lots: [CreditLotBalance]
}
public struct DebtTimelinePoint: Equatable, Sendable {
    public var date: Day; public var balance: Int64; public var components: [FinancialComponent: Int64]
}
public enum FinancialLedger {
    public static func operationsByAccount(in db: Database) -> [UUID: [Operation]] {
        let accounts = Set(db.financeData.contracts.map(\.accountID))
        var result: [UUID: [Operation]] = [:]
        for operation in db.operations {
            if accounts.contains(operation.accountID) { result[operation.accountID, default: []].append(operation) }
            if let destination = operation.toAccountID, destination != operation.accountID, accounts.contains(destination) { result[destination, default: []].append(operation) }
        }
        return result
    }
    public static func migrate(_ old: Database) throws -> Database {
        guard (1...3).contains(old.version) else { throw BudgetError.newerVersion }
        var db = old; db.version = 3
        return db
    }
    public static func depositWarnings(_ operation: Operation, db: Database) throws -> [String] {
        guard operation.kind == .transfer || operation.kind == .expense, operation.financial?.groupID == nil else { return [] }
        var warnings: [String] = []
        if let id = operation.toAccountID, let contract = db.contract(for: id), contract.kind == .deposit, contract.terms(on: operation.date)?.deposit.allowTopUp == false { warnings.append("Пополнение запрещено условиями депозита.") }
        if let contract = db.contract(for: operation.accountID), contract.kind == .deposit, let terms = contract.terms(on: operation.date) {
            if !terms.deposit.allowWithdrawal { warnings.append("Частичное снятие запрещено условиями депозита.") }
            let balance = try db.balance(operation.accountID, on: operation.date)
            let old = db.operations.first { $0.id == operation.id }?.posting(for: operation.accountID) ?? 0
            if try Money.add(try Money.add(balance, -old), -operation.amount) < terms.deposit.minimumBalance { warnings.append("Остаток станет ниже неснижаемой суммы.") }
        }
        return warnings
    }
    public static func saveContract(_ value: FinancialContract, in db: inout Database) throws {
        var candidate = db; var contract = value
        guard let index = candidate.accounts.firstIndex(where: { $0.id == contract.accountID }), contract.kind != .ordinary else { throw BudgetError.invalid("Выберите финансовый счёт.") }
        if let previous = candidate.contract(for: contract.accountID), previous.id != contract.id { throw BudgetError.conflict("У счёта уже есть договор.") }
        if let previous = candidate.contract(for: contract.accountID), previous.kind != contract.kind { throw BudgetError.conflict("Для другого типа договора создайте новый счёт.") }
        contract.modifiedAt = Date()
        candidate.accounts[index].financialKind = contract.kind; candidate.accounts[index].contractID = contract.id
        var book = candidate.financeData
        if let i = book.contracts.firstIndex(where: { $0.id == contract.id }) { book.contracts[i] = contract } else { book.contracts.append(contract) }
        candidate.finances = book
        try validate(candidate); db = candidate
    }
    public static func saveBank(_ bank: UserBank, in db: inout Database) throws {
        var copy = bank; copy.name = bank.name.trimmingCharacters(in: .whitespacesAndNewlines); try Ledger.nonempty(copy.name)
        if let bytes = copy.logo { copy.logo = try BankImages.normalized(bytes) }
        var book = db.financeData
        if let i = book.banks.firstIndex(where: { $0.id == bank.id }) { book.banks[i] = copy } else { book.banks.append(copy) }
        db.finances = book
    }
    public static func replaceGroup(_ id: UUID, in db: inout Database, with mutation: (inout Database) throws -> Void) throws {
        let original = db.financeData.groups.first { $0.id == id }
        var candidate = db; try deleteGroup(id, in: &candidate)
        let remainingIDs = Set(candidate.financeData.groups.map(\.id))
        try mutation(&candidate)
        if let original, let sourceKey = original.importSourceKey {
            let replacements = candidate.financeData.groups.indices.filter { !remainingIDs.contains(candidate.financeData.groups[$0].id) && candidate.financeData.groups[$0].contractID == original.contractID }
            guard replacements.count == 1 else { throw BudgetError.invalid("Изменение импортированного платежа должно сохранить одну финансовую группу.") }
            candidate.finances?.groups[replacements[0]].importSourceKey = sourceKey
            candidate.finances?.groups[replacements[0]].importRowFingerprint = original.importRowFingerprint
            // A changed fact requires review, even if the original CSV mapping is selected again.
            candidate.finances?.groups[replacements[0]].importMappingFingerprint = nil
        }
        try Ledger.validate(candidate); db = candidate
    }
    public static func renewDeposit(_ id: UUID, start: Day, end: Day, annualPercent: String?, in db: inout Database) throws {
        guard var contract = db.financeData.contracts.first(where: { $0.id == id }), contract.kind == .deposit, contract.status == .active, contract.end == start, start <= .today, end > start else { throw BudgetError.invalid("Новый срок должен начинаться после окончания текущего. Будущая пролонгация остаётся планом.") }
        let principal = try db.balance(contract.accountID, on: start)
        contract.previousPeriods = (contract.previousPeriods ?? []) + [FinancialContractPeriod(start: contract.start, end: contract.end, principal: contract.originalPrincipal, terms: contract.terms)]
        var terms = contract.terms(on: start) ?? contract.terms.last!; terms.id = UUID(); terms.effectiveFrom = start; terms.annualPercent = annualPercent; terms.indexName = ""; terms.indexPercent = nil; terms.scenarioRate = annualPercent == nil; terms.deposit.renewalDecisionOn = nil
        contract.start = start; contract.end = end; contract.originalPrincipal = max(0, principal); contract.firstPayment = nil
        contract.terms.removeAll { $0.effectiveFrom == start }; contract.terms.append(terms)
        try saveContract(contract, in: &db)
    }
    public static func closeDeposit(_ id: UUID, to destination: UUID, interestAdjustment: Int64, fee: Int64 = 0, newTax: Int64 = 0, receivedAmount: Int64? = nil, date: Day = .today, in db: inout Database) throws {
        var candidate = db
        guard let contract = db.financeData.contracts.first(where: { $0.id == id }), contract.kind == .deposit, contract.status == .active, date >= contract.start, fee >= 0, newTax >= 0 else { throw BudgetError.invalid("Проверьте закрытие депозита.") }
        var operations: [Operation] = []
        if interestAdjustment != 0 {
            let positive = interestAdjustment > 0
            var operation = Operation(kind: positive ? .income : .expense, date: date, accountID: contract.accountID, amount: positive ? interestAdjustment : try FinanceMath.positiveMagnitude(interestAdjustment))
            operation.categoryID = try category(positive ? "Проценты по депозитам" : "Перерасчёт процентов депозита", kind: operation.kind, db: &candidate); operation.financial = FinanceOperationDetails(component: .interest); operations.append(operation)
        }
        for (component, amount, name) in [(FinancialComponent.fee, fee, "Комиссия закрытия депозита"), (.tax, newTax, "Налог на процентный доход")] where amount > 0 {
            var operation = Operation(kind: .expense, date: date, accountID: contract.accountID, amount: amount); operation.categoryID = try category(name, kind: .expense, db: &candidate); operation.financial = FinanceOperationDetails(component: component); operations.append(operation)
        }
        let returned = try Money.add(try Money.add(try Money.add(candidate.balance(contract.accountID, on: date), interestAdjustment), -fee), -newTax)
        guard returned > 0 else { throw BudgetError.invalid("После удержаний не остаётся положительной суммы возврата.") }
        let source = try candidate.account(contract.accountID), target = try candidate.account(destination)
        if source.currency != target.currency && receivedAmount == nil { throw BudgetError.invalid("Введите фактическую сумму возврата в валюте получателя.") }
        var transfer = Operation(kind: .transfer, date: date, accountID: contract.accountID, amount: returned); transfer.toAccountID = destination; transfer.toAmount = receivedAmount ?? returned; transfer.financial = FinanceOperationDetails(component: .principal); operations.append(transfer)
        _ = try recordGroup(contract: contract, operations: operations, eventID: FinancialEngine.eventKey(contract.id, kind: .depositMaturity, anchor: contract.end?.rawValue ?? date.rawValue), fulfilledAmount: returned, title: "Закрытие депозита", in: &candidate)
        guard try candidate.balance(contract.accountID, on: date) == 0, let index = candidate.finances?.contracts.firstIndex(where: { $0.id == id }) else { throw BudgetError.corrupt }
        candidate.finances?.contracts[index].status = .closed; try Ledger.validate(candidate); db = candidate
    }
    public static func closeContract(_ id: UUID, in db: inout Database) throws {
        guard let i = db.finances?.contracts.firstIndex(where: { $0.id == id }), let contract = db.finances?.contracts[i] else { throw BudgetError.missing("Договор не найден.") }
        guard try db.balance(contract.accountID) == 0 else { throw BudgetError.invalid("Перед закрытием урегулируйте остаток / задолженность.") }
        let pending = try FinancialEngine.events(contract: contract, db: db).filter { !$0.isFulfilled && $0.date <= .today && ($0.amount ?? 0) > 0 }
        guard pending.isEmpty else { throw BudgetError.invalid("Есть неподтверждённые события. Свяжите платежи или исправьте график.") }
        db.finances?.contracts[i].status = .closed
    }
    private static func replay(accountID: UUID, db: Database, on day: Day, observe: ((DebtTimelinePoint) -> Void)? = nil, observeLots: ((CreditExposurePoint) -> Void)? = nil, observeAllocations: ((UUID, [FinancialAllocation]) -> Void)? = nil) throws -> (Int64, [FinancialComponent: Int64], [CreditLotBalance]) {
        let account = try db.account(accountID)
        guard account.kind.isDebt else { throw BudgetError.invalid("Счёт не является кредитным.") }
        let contract = db.contract(for: accountID)
        var balance: Int64 = 0, components: [FinancialComponent: Int64] = [:], lots: [CreditLotBalance] = []
        var order = contract?.terms(on: day)?.credit.repaymentOrder ?? .chargesFirst
        var replayDay = day
        var repayments: [(Day, Int64)] = []
        let records = db.operations.filter { $0.date <= day && ($0.accountID == accountID || $0.toAccountID == accountID) }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        func reduceLots(_ amount: Int64, id: UUID? = nil) throws {
            var remaining = amount
            if let id { guard lots.contains(where: { $0.id == id && $0.amount >= amount }) else { throw BudgetError.invalid("Выбранный транш не покрывает распределённую сумму.") } }
            var rates: [CreditTransactionKind: Decimal] = [:]
            if order == .highestRate, id == nil {
                guard let terms = contract?.terms(on: replayDay) else { throw BudgetError.invalid("Неизвестны условия распределения. Задайте его вручную.") }
                for lot in lots where lot.amount > 0 {
                    let rate = try terms.credit.buckets.first(where: { $0.kind == lot.kind })?.annualPercent.map { try Money.decimal($0) / 100 } ?? terms.rate()
                    guard let rate else { throw BudgetError.invalid("Неизвестна ставка транша. Для выбора высокой ставки распределите платёж вручную.") }
                    rates[lot.kind] = rate
                }
            }
            let indexes = lots.indices.sorted { left, right in
                if left == right { return false }
                if let id, (lots[left].id == id) != (lots[right].id == id) { return lots[left].id == id }
                if order == .highestRate, let lr = rates[lots[left].kind], let rr = rates[lots[right].kind], lr != rr { return lr > rr }
                return lots[left].date == lots[right].date ? left < right : lots[left].date < lots[right].date
            }
            for index in indexes where remaining > 0 { let used = min(remaining, lots[index].amount); lots[index].amount -= used; remaining -= used }
            guard remaining == 0 else { throw BudgetError.invalid("Погашение превышает основной долг траншей.") }
        }
        func reduce(_ component: FinancialComponent, _ amount: Int64, lotID: UUID? = nil) throws {
            guard amount >= 0, amount <= (components[component] ?? 0) else { throw BudgetError.invalid("Распределение превышает непогашенный компонент «\(component.title)».") }
            if component == .principal { try reduceLots(amount, id: lotID) }
            components[component, default: 0] -= amount
        }
        func automaticallyApply(_ amount: Int64, using selected: RepaymentOrder) throws {
            let oldOrder = order; order = selected; defer { order = oldOrder }
            var remaining = amount
            let priorities: [FinancialComponent] = selected == .principalFirst || selected == .fifo || selected == .highestRate ? [.principal, .interest, .fee, .penalty, .tax, .escrow, .unallocated] : [.penalty, .fee, .interest, .tax, .escrow, .principal, .unallocated]
            if selected == .proportional {
                let present = priorities.filter { (components[$0] ?? 0) > 0 }
                let currentDebt = try components.values.reduce(Int64(0)) { try Money.add($0, $1) }; var applied: Int64 = 0
                for (index, component) in present.enumerated() {
                    let part = index == present.count - 1 ? remaining - applied : min(components[component] ?? 0, try FinanceMath.rounded(Decimal(remaining) * Decimal(components[component] ?? 0) / Decimal(currentDebt), mode: .truncate))
                    try reduce(component, part); applied += part
                }
                remaining = 0
            } else {
                guard selected != .manual else { throw BudgetError.invalid("Требуется ручное распределение части платежа.") }
                for component in priorities where remaining > 0 { let used = min(remaining, components[component] ?? 0); try reduce(component, used); remaining -= used }
            }
            guard remaining == 0 else { throw BudgetError.invalid("Осталась нераспределённая сумма погашения.") }
        }
        for operation in records {
            replayDay = operation.date
            order = contract?.terms(on: operation.date)?.credit.repaymentOrder ?? .chargesFirst
            let posting = operation.posting(for: accountID), oldDebt = balance < 0 ? try FinanceMath.positiveMagnitude(balance) : 0
            let next = try Money.add(balance, posting)
            if posting < 0 {
                let debit = try FinanceMath.positiveMagnitude(posting); let increase = debit - min(debit, max(0, balance))
                if increase > 0 {
                    let supplied = operation.financial?.allocations ?? []
                    let allocations: [FinancialAllocation]
                    if operation.kind == .opening || operation.kind == .adjustment {
                        allocations = supplied.isEmpty ? [FinancialAllocation(operation.kind == .opening ? .principal : .unallocated, increase)] : supplied
                    } else { allocations = [FinancialAllocation(operation.financial?.component ?? .principal, increase)] }
                    let total = try allocations.reduce(Int64(0)) { try Money.add($0, $1.amount) }
                    guard total == increase else { throw BudgetError.invalid("Состав начального долга / корректировки не совпадает с изменением задолженности.") }
                    for allocation in allocations {
                        components[allocation.component] = try Money.add(components[allocation.component] ?? 0, allocation.amount)
                        if allocation.component == .principal { lots.append(CreditLotBalance(id: operation.id, date: operation.date, kind: operation.financial?.transactionKind ?? .purchase, amount: allocation.amount)) }
                    }
                }
            } else if posting > 0 && oldDebt > 0 {
                let priorComponents = observeAllocations == nil ? [:] : components
                let priorLots = observeAllocations == nil ? [] : lots
                var remaining = min(posting, oldDebt)
                let manual = (operation.financial?.allocations ?? []).filter { $0.component != .ownFunds }
                if !manual.isEmpty {
                    let total = try manual.reduce(Int64(0)) { try Money.add($0, $1.amount) }
                    guard total == remaining else { throw BudgetError.invalid("Распределите всю погашенную задолженность.") }
                    for allocation in manual { try reduce(allocation.component, allocation.amount, lotID: allocation.lotID) }; remaining = 0
                } else {
                    guard order != .manual else { throw BudgetError.invalid("По условиям договора требуется ручное распределение погашения.") }
                    if let excess = contract?.terms(on: operation.date)?.credit.excessRepaymentOrder {
                        guard let statement = db.financeData.statements.filter({ $0.contractID == contract?.id && $0.closedOn < operation.date }).max(by: { $0.closedOn < $1.closedOn }) else { throw BudgetError.invalid("Для отдельных правил минимума и превышения введите выписку или распределите платёж вручную.") }
                        let paid = try repayments.filter { $0.0 > statement.closedOn }.reduce(Int64(0)) { try Money.add($0, $1.1) }
                        let minimumPart = min(remaining, max(0, statement.minimum - paid))
                        if minimumPart > 0 { try automaticallyApply(minimumPart, using: order) }
                        if remaining > minimumPart { try automaticallyApply(remaining - minimumPart, using: excess) }
                    } else { try automaticallyApply(remaining, using: order) }
                    remaining = 0
                }
                guard remaining == 0 else { throw BudgetError.invalid("Осталась нераспределённая сумма погашения.") }
                if let observeAllocations {
                    var allocation: [FinancialAllocation] = []
                    let afterLots = Dictionary(uniqueKeysWithValues: lots.map { ($0.id, $0.amount) })
                    for lot in priorLots { let paid = lot.amount - (afterLots[lot.id] ?? 0); if paid > 0 { allocation.append(FinancialAllocation(.principal, paid, lotID: lot.id)) } }
                    for component in FinancialComponent.allCases where component != .principal && component != .ownFunds { let paid = (priorComponents[component] ?? 0) - (components[component] ?? 0); if paid > 0 { allocation.append(FinancialAllocation(component, paid)) } }
                    observeAllocations(operation.id, allocation)
                }
            }
            if posting > 0 { repayments.append((operation.date, min(posting, oldDebt))) }
            balance = next
            observeLots?(CreditExposurePoint(date: operation.date, lots: lots))
            observe?(DebtTimelinePoint(date: operation.date, balance: balance, components: components))
        }
        let debt = balance < 0 ? try FinanceMath.positiveMagnitude(balance) : 0
        guard try components.values.reduce(Int64(0), { try Money.add($0, $1) }) == debt else { throw BudgetError.invalid("Компоненты задолженности не согласованы с балансом.") }
        return (balance, components, lots.filter { $0.amount > 0 })
    }
    public static func debtTimeline(accountID: UUID, db: Database, through day: Day = .today) throws -> [DebtTimelinePoint] {
        var points: [DebtTimelinePoint] = []
        _ = try replay(accountID: accountID, db: db, on: day, observe: { point in
            if points.last?.date == point.date { points[points.count - 1] = point } else { points.append(point) }
        })
        return points
    }
    public static func creditExposure(accountID: UUID, db: Database, through day: Day) throws -> [CreditExposurePoint] {
        var points: [CreditExposurePoint] = []
        _ = try replay(accountID: accountID, db: db, on: day, observeLots: { point in
            if points.last?.date == point.date { points[points.count - 1] = point } else { points.append(point) }
        })
        return points
    }
    public static func debt(accountID: UUID, db: Database, on day: Day = .today) throws -> DebtSummary {
        let (balance, values, _) = try replay(accountID: accountID, db: db, on: day)
        let debt = balance < 0 ? try FinanceMath.positiveMagnitude(balance) : 0
        let terms = db.contract(for: accountID)?.terms(on: day)
        let limit = try db.account(accountID).kind == .revolvingCredit ? terms?.credit.limit : nil
        let used = limit == nil ? nil : terms?.credit.chargesUseLimit == true ? debt : values[.principal] ?? 0
        return DebtSummary(balance: balance, debt: debt, ownFunds: max(0, balance), components: FinancialComponent.allCases.compactMap { c in guard let value = values[c], value > 0 else { return nil }; return FinancialAllocation(c, value) }, limit: limit, usedLimit: used, available: limit.map { max(0, $0 - (used ?? 0)) }, overLimit: limit.map { max(0, (used ?? 0) - $0) })
    }
    public static func creditLots(accountID: UUID, db: Database, on day: Day = .today) throws -> [CreditLotBalance] { try replay(accountID: accountID, db: db, on: day).2 }
    public static func paymentAllocations(accountID: UUID, db: Database, through day: Day = .today) throws -> [UUID: [FinancialAllocation]] {
        var values: [UUID: [FinancialAllocation]] = [:]
        _ = try replay(accountID: accountID, db: db, on: day, observeAllocations: { values[$0] = $1 })
        return values
    }
    public static func recordGroup(contract: FinancialContract, operations: [Operation], eventID: String? = nil, fulfilledAmount: Int64 = 0, title: String, in db: inout Database) throws -> UUID {
        var candidate = db; var group = FinanceOperationGroup(contractID: contract.id, operationIDs: operations.map(\.id), eventID: eventID, title: title)
        guard !operations.isEmpty, Set(operations.map(\.id)).count == operations.count, !operations.contains(where: { operation in candidate.operations.contains { $0.id == operation.id } }) else { throw BudgetError.conflict("Операции группы уже существуют или повторяются.") }
        let now = Date()
        for (index, var operation) in operations.enumerated() {
            var details = operation.financial ?? FinanceOperationDetails(); details.groupID = group.id; details.contractID = contract.id; details.eventID = eventID; operation.financial = details
            operation.createdAt = now.addingTimeInterval(Double(index) / 1_000_000)
            if contract.kind.isDebt, operation.toAccountID == contract.accountID, details.allocations.isEmpty {
                var projection = candidate
                projection.operations.append(operation)
                let resolved = try paymentAllocations(accountID: contract.accountID, db: projection, through: operation.date)[operation.id] ?? []
                details.allocations = resolved; operation.financial = details
            }
            try Ledger.saveOperation(operation, in: &candidate)
        }
        group.operationIDs = operations.map(\.id)
        var book = candidate.financeData; book.groups.append(group)
        if let eventID, fulfilledAmount > 0 { book.fulfillments.append(FinanceFulfillment(eventID: eventID, contractID: contract.id, operationIDs: group.operationIDs, amount: fulfilledAmount)) }
        candidate.finances = book; try Ledger.validate(candidate); db = candidate; return group.id
    }
    private static func category(_ name: String, kind: OperationKind, db: inout Database) throws -> UUID {
        if let c = db.categories.first(where: { !$0.archived && $0.kind == kind && Ledger.normalized($0.name) == Ledger.normalized(name) }) { return c.id }
        let c = Category(name: name, kind: kind); try Ledger.saveCategory(c, in: &db); return c.id
    }
    public static func confirmDeposit(contractID: UUID, eventID: String, gross: Int64, tax: Int64 = 0, payoutAccountID: UUID? = nil, receivedAmount: Int64? = nil, date: Day = .today, in db: inout Database) throws {
        var candidate = db
        guard let contract = candidate.finances?.contracts.first(where: { $0.id == contractID }), contract.kind == .deposit, gross > 0, tax >= 0, tax < gross else { throw BudgetError.invalid("Проверьте депозит, проценты и удержание.") }
        guard !candidate.financeData.fulfillments.contains(where: { $0.eventID == eventID }) else { throw BudgetError.conflict("Выплата уже подтверждена. Сначала измените / удалите связанную группу.") }
        var income = Operation(kind: .income, date: date, accountID: contract.accountID, amount: gross); income.categoryID = try category("Проценты по депозитам", kind: .income, db: &candidate); income.financial = FinanceOperationDetails(component: .interest)
        var operations = [income]
        if tax > 0 { var expense = Operation(kind: .expense, date: date, accountID: contract.accountID, amount: tax); expense.categoryID = try category("Налог на процентный доход", kind: .expense, db: &candidate); expense.financial = FinanceOperationDetails(component: .tax); operations.append(expense) }
        if let destination = payoutAccountID {
            var transfer = Operation(kind: .transfer, date: date, accountID: contract.accountID, amount: gross - tax); transfer.toAccountID = destination
            let source = try candidate.account(contract.accountID), target = try candidate.account(destination)
            if source.currency != target.currency && receivedAmount == nil { throw BudgetError.invalid("Введите фактическую сумму зачисления в валюте получателя.") }
            transfer.toAmount = receivedAmount ?? transfer.amount; transfer.financial = FinanceOperationDetails(component: .interest); operations.append(transfer)
        }
        _ = try recordGroup(contract: contract, operations: operations, eventID: eventID, fulfilledAmount: gross, title: "Выплата процентов", in: &candidate); db = candidate
    }
    public static func payDepositTax(contractID: UUID, eventID: String, from accountID: UUID, amount: Int64, coveredInContractCurrency: Int64? = nil, date: Day = .today, in db: inout Database) throws {
        var candidate = db
        guard let contract = candidate.financeData.contracts.first(where: { $0.id == contractID }), contract.kind == .deposit, amount > 0,
              try candidate.account(accountID).kind == .ordinary else { throw BudgetError.invalid("Выберите депозит и обычный счёт оплаты налога.") }
        guard !candidate.financeData.fulfillments.contains(where: { $0.eventID == eventID }) else { throw BudgetError.conflict("Налог уже подтверждён. Измените связанную группу.") }
        let payer = try candidate.account(accountID), deposit = try candidate.account(contract.accountID)
        if payer.currency != deposit.currency && coveredInContractCurrency == nil { throw BudgetError.invalid("Введите покрытую сумму налога в валюте депозита.") }
        guard (coveredInContractCurrency ?? amount) > 0, payer.currency != deposit.currency || coveredInContractCurrency == nil || coveredInContractCurrency == amount else { throw BudgetError.invalid("Проверьте покрытую сумму налога и валюту списания.") }
        var expense = Operation(kind: .expense, date: date, accountID: accountID, amount: amount)
        expense.categoryID = try category("Налог на процентный доход", kind: .expense, db: &candidate); expense.financial = FinanceOperationDetails(component: .tax)
        _ = try recordGroup(contract: contract, operations: [expense], eventID: eventID, fulfilledAmount: coveredInContractCurrency ?? amount, title: "Налог на процентный доход", in: &candidate)
        db = candidate
    }
    public static func payDebt(contractID: UUID, from accountID: UUID, amount: Int64, interestCharge: Int64 = 0, feeCharge: Int64 = 0, penaltyCharge: Int64 = 0, escrowAmount: Int64 = 0, escrowAccountID: UUID? = nil, escrowReceivedAmount: Int64? = nil, allocations: [FinancialAllocation] = [], statementAllocations: [CreditStatementAllocation] = [], eventID: String? = nil, receivedAmount: Int64? = nil, date: Day = .today, prepayment: Bool = false, prepaymentMode: PrepaymentMode? = nil, creditedAt: Date? = nil, in db: inout Database) throws {
        var candidate = db
        guard let contract = candidate.finances?.contracts.first(where: { $0.id == contractID }), contract.kind.isDebt, amount > 0, interestCharge >= 0, feeCharge >= 0, penaltyCharge >= 0, escrowAmount >= 0, escrowAmount < amount else { throw BudgetError.invalid("Проверьте договор, платёж и начисления.") }
        if let eventID, let event = try FinancialEngine.events(contract: contract, db: candidate, asOf: date).first(where: { $0.id == eventID }), event.isFulfilled { throw BudgetError.conflict("Это событие уже исполнено.") }
        var operations: [Operation] = []
        for (component, charge, name) in [(FinancialComponent.interest, interestCharge, "Проценты по кредитам"), (.fee, feeCharge, "Комиссии кредитора"), (.penalty, penaltyCharge, "Штрафы кредитора")] where charge > 0 {
            var expense = Operation(kind: .expense, date: date, accountID: contract.accountID, amount: charge); expense.categoryID = try category(name, kind: .expense, db: &candidate); expense.financial = FinanceOperationDetails(component: component); operations.append(expense)
        }
        var transfer = Operation(kind: .transfer, date: date, accountID: accountID, amount: amount - escrowAmount); transfer.toAccountID = contract.accountID
        let source = try candidate.account(accountID), target = try candidate.account(contract.accountID)
        if source.currency != target.currency && receivedAmount == nil { throw BudgetError.invalid("Введите фактическое погашение в валюте договора.") }
        if escrowAmount > 0 {
            guard let escrowAccountID, escrowAccountID != contract.accountID, escrowAccountID != accountID else { throw BudgetError.invalid("Выберите отдельный счёт escrow.") }
            let escrowAccount = try candidate.account(escrowAccountID)
            guard escrowAccount.kind == .ordinary else { throw BudgetError.invalid("Escrow учитывается на обычном счёте.") }
            if source.currency != target.currency { throw BudgetError.invalid("Для общего платежа с escrow валюта списания должна совпадать с валютой договора. Разные валюты оформите отдельными переводами с фактическим зачислением.") }
            if source.currency != escrowAccount.currency && escrowReceivedAmount == nil { throw BudgetError.invalid("Введите фактическое зачисление escrow в валюте получателя.") }
            var escrowTransfer = Operation(kind: .transfer, date: date, accountID: accountID, amount: escrowAmount); escrowTransfer.toAccountID = escrowAccountID; escrowTransfer.toAmount = escrowReceivedAmount ?? escrowAmount; escrowTransfer.financial = FinanceOperationDetails(component: .escrow); operations.append(escrowTransfer)
        }
        transfer.toAmount = receivedAmount ?? transfer.amount; var details = FinanceOperationDetails(allocations: allocations); details.prepayment = prepayment; details.prepaymentMode = prepaymentMode; details.creditedAt = creditedAt
        details.statementAllocations = statementAllocations.isEmpty ? nil : statementAllocations
        if prepayment, prepaymentMode != nil, contract.kind == .mortgage || contract.kind == .termLoan {
            if prepaymentMode != .manual, contract.frequency == .manual || contract.terms(on: date)?.loan.method == .manual { throw BudgetError.invalid("Для ручного графика выберите ручной режим и внесите новый график банка.") }
            let before = try FinancialEngine.events(contract: contract, db: db, asOf: date).filter { $0.kind == .loanPayment && $0.date > date }
            if let first = before.first(where: { $0.amount(.principal) > 0 || $0.amount(.interest) > 0 }), first.amount != nil, first.accuracy == .calculated { details.prepaymentRegularPayment = try Money.add(first.amount(.principal), first.amount(.interest)) }
            details.prepaymentScheduleEnd = before.last?.accrualEnd
        }
        transfer.financial = details
        if contract.kind == .revolvingCredit && details.statementAllocations == nil {
            let statements = candidate.financeData.statements.filter { $0.contractID == contract.id }
            if !statements.isEmpty {
                var projection = candidate; projection.operations.append(transfer)
                let receipts = try CreditStatements.receipts(statements: statements, contract: contract, db: projection, asOf: date)
                let resolved = receipts.byStatement.compactMap { id, payments -> CreditStatementAllocation? in
                    let amount = payments.filter { $0.operation.id == transfer.id }.reduce(Int64(0)) { $0 + $1.amount }
                    return amount > 0 ? CreditStatementAllocation(statementID: id, amount: amount) : nil
                }.sorted { $0.statementID.uuidString < $1.statementID.uuidString }
                details.statementAllocations = resolved.isEmpty ? nil : resolved; transfer.financial = details
            }
        }
        operations.append(transfer)
        _ = try recordGroup(contract: contract, operations: operations, eventID: eventID, fulfilledAmount: try Money.add(transfer.toAmount ?? transfer.amount, escrowAmount), title: prepayment ? "Досрочное погашение" : "Платёж кредитору", in: &candidate); db = candidate
    }
    public static func issueCredit(contractID: UUID, to accountID: UUID, amount: Int64, receivedAmount: Int64? = nil, date: Day = .today, in db: inout Database) throws {
        guard let contract = db.finances?.contracts.first(where: { $0.id == contractID }), contract.kind.isDebt else { throw BudgetError.invalid("Кредитный договор не найден.") }
        var operation = Operation(kind: .transfer, date: date, accountID: contract.accountID, amount: amount); operation.toAccountID = accountID
        if try db.account(contract.accountID).currency != db.account(accountID).currency && receivedAmount == nil { throw BudgetError.invalid("Введите фактическую сумму получения кредита.") }
        operation.toAmount = receivedAmount ?? amount; operation.financial = FinanceOperationDetails(component: .principal)
        _ = try recordGroup(contract: contract, operations: [operation], title: "Выдача кредита", in: &db)
    }
    public static func link(event: FinanceEvent, operationIDs: [UUID], amount: Int64, in db: inout Database) throws {
        guard amount > 0, !operationIDs.isEmpty, Set(operationIDs).count == operationIDs.count else { throw BudgetError.invalid("Выберите фактические операции и покрытую сумму.") }
        guard let contract = db.finances?.contracts.first(where: { $0.id == event.contractID }) else { throw BudgetError.missing("Договор не найден.") }
        let separateDepositTax = contract.kind == .deposit && event.kind == .tax
        let allowed = db.operations.filter { operation in
            guard operationIDs.contains(operation.id) else { return false }
            if separateDepositTax {
                return operation.kind == .expense && (try? db.account(operation.accountID).kind) == .ordinary && (try? db.account(operation.accountID).currency) == (try? db.account(contract.accountID).currency)
            }
            return operation.accountID == contract.accountID || operation.toAccountID == contract.accountID
        }
        guard allowed.count == operationIDs.count else { throw BudgetError.invalid("Операции не относятся к выбранному договору.") }
        let actual = try allowed.reduce(Int64(0)) { total, operation in
            let covered: Int64 = separateDepositTax ? operation.amount : contract.kind == .deposit ? (operation.kind == .income ? operation.amount : 0) : (operation.toAccountID == contract.accountID ? operation.toAmount ?? 0 : operation.kind == .income ? operation.amount : 0)
            let used = try db.financeData.fulfillments.filter { $0.operationIDs.contains(operation.id) }.reduce(Int64(0)) { try Money.add($0, $1.amount) }
            return try Money.add(total, max(0, covered - used))
        }
        guard amount <= actual, event.remaining.map({ amount <= $0 }) ?? true else { throw BudgetError.invalid("Покрытая сумма превышает доступный факт / остаток события.") }
        var book = db.financeData; book.fulfillments.append(FinanceFulfillment(eventID: event.id, contractID: event.contractID, operationIDs: operationIDs, amount: amount)); db.finances = book
    }
    public static func deleteGroup(_ groupID: UUID, in db: inout Database) throws {
        guard let group = db.finances?.groups.first(where: { $0.id == groupID }) else { throw BudgetError.missing("Группа операций не найдена.") }
        let ids = Set(group.operationIDs)
        for o in db.operations where ids.contains(o.id) { guard !(try db.account(o.accountID).archived), o.toAccountID.flatMap({ id in db.accounts.first { $0.id == id } })?.archived != true else { throw BudgetError.invalid("Верните затронутые счета из архива.") } }
        var candidate = db
        if group.title == "Закрытие депозита", let index = candidate.finances?.contracts.firstIndex(where: { $0.id == group.contractID }) { candidate.finances?.contracts[index].status = .active }
        candidate.operations.removeAll { ids.contains($0.id) }; candidate.finances?.groups.removeAll { $0.id == groupID }; candidate.finances?.fulfillments.removeAll { !$0.operationIDs.filter { ids.contains($0) }.isEmpty }
        ScheduledPayments.detachOperations(ids, in: &candidate)
        try Ledger.validate(candidate); db = candidate
    }
    public static func validate(_ db: Database) throws {
        guard let book = db.finances else {
            guard db.accounts.allSatisfy({ $0.contractID == nil }), db.operations.allSatisfy({ $0.financial?.groupID == nil }) else { throw BudgetError.corrupt }; return
        }
        func unique<T: Hashable>(_ ids: [T]) throws { guard Set(ids).count == ids.count else { throw BudgetError.corrupt } }
        try unique(book.contracts.map(\.id)); try unique(book.contracts.map(\.accountID)); try unique(book.banks.map(\.id)); try unique(book.groups.map(\.id)); try unique(book.statements.map(\.id)); try unique(book.fulfillments.map(\.id)); try unique(book.calendars.map(\.id))
        try unique(book.groups.compactMap(\.importSourceKey))
        let debtAccounts = Set(book.contracts.filter { $0.kind.isDebt }.map(\.accountID))
        var debtOperations: [UUID: [Operation]] = [:]
        for operation in db.operations {
            if debtAccounts.contains(operation.accountID) { debtOperations[operation.accountID, default: []].append(operation) }
            if let target = operation.toAccountID, debtAccounts.contains(target), target != operation.accountID { debtOperations[target, default: []].append(operation) }
        }
        for bank in book.banks { try Ledger.nonempty(bank.name); if let logo = bank.logo { try BankImages.validate(logo) } }
        for contract in book.contracts {
            let account = try db.account(contract.accountID)
            guard contract.kind == account.kind, contract.kind != .ordinary, account.contractID == contract.id, contract.end.map({ $0 > contract.start }) ?? (contract.kind == .deposit || contract.kind == .revolvingCredit), contract.originalPrincipal >= 0, (1...1200).contains(contract.forecastMonths), TimeZone(identifier: contract.timeZoneID) != nil else { throw BudgetError.invalid("Проверьте тип, даты, сумму и часовой пояс договора.") }
            guard contract.cutoffHour.map({ (0...23).contains($0) }) ?? true else { throw BudgetError.invalid("Предельный час зачисления должен быть от 0 до 23.") }
            guard !contract.terms.isEmpty, contract.terms.map(\.effectiveFrom).min()! <= max(contract.start, account.openedOn) else { throw BudgetError.invalid("Задайте условия с начала учёта.") }
            try unique(contract.terms.map(\.id)); try unique(contract.terms.map(\.effectiveFrom)); try unique(contract.manualRows.map(\.id))
            if let id = contract.paymentAccountID { guard id != account.id else { throw BudgetError.invalid("Счёт оплаты должен отличаться от кредитного.") }; _ = try db.account(id) }
            for terms in contract.terms {
                guard terms.deposit.accrualFrequency != .manual, terms.deposit.capitalizationFrequency != .manual else { throw BudgetError.invalid("Для нестандартных периодов используйте ручной график выплаты.") }
                guard terms.deposit.separateTaxFrequency != .manual else { throw BudgetError.invalid("Для нестандартного налога добавьте отдельную строку банковского графика.") }
                if let id = terms.deposit.taxPaymentAccountID { guard try db.account(id).kind == .ordinary else { throw BudgetError.invalid("Налог отдельно оплачивается с обычного счёта.") } }
                if terms.deposit.roundOnlyAtFinalPayout == true { guard contract.kind == .deposit, contract.frequency == .maturity, terms.roundingPoint == .event else { throw BudgetError.invalid("Округление только в конце требует выплаты в конце срока и отключённого ежедневного округления.") } }
                for rate in [terms.annualPercent, terms.indexPercent, terms.marginPercent, terms.floorPercent, terms.capPercent, terms.deposit.taxPercent, terms.deposit.earlyAnnualPercent, terms.credit.minimumPercent, terms.credit.penaltyAnnualPercent, terms.loan.prepaymentFeePercent].compactMap({ $0 }) { guard try Money.decimal(rate) >= 0 else { throw BudgetError.invalid("Ставка не может быть отрицательной; нестандартное условие задайте ручным графиком.") } }
                if let floor = terms.floorPercent, let cap = terms.capPercent { guard try Money.decimal(floor) <= Money.decimal(cap) else { throw BudgetError.invalid("Минимальная ставка выше максимальной.") } }
                guard terms.credit.limit >= 0, terms.credit.minimumFixed >= 0, terms.credit.minimumFloor >= 0, terms.credit.graceDays >= 0, terms.credit.dueDays >= 0, (1...31).contains(terms.credit.closingDay), terms.credit.lateFee >= 0, terms.loan.escrowPayment >= 0, terms.loan.paymentFee >= 0, terms.deposit.minimumBalance >= 0, terms.deposit.earlyFee >= 0 else { throw BudgetError.invalid("Лимиты, комиссии и суммы должны быть неотрицательными.") }
                guard terms.credit.graceRestoreStatements.map({ (1...120).contains($0) }) ?? true else { throw BudgetError.invalid("Для восстановления льготы задайте от 1 до 120 выписок.") }
                for tier in terms.deposit.tiers { guard tier.lowerMinor >= 0, try Money.decimal(tier.annualPercent) >= 0 else { throw BudgetError.invalid("Некорректный диапазон ставки.") } }; try unique(terms.deposit.tiers.map(\.lowerMinor))
                for rule in terms.credit.buckets { if let rate = rule.annualPercent { guard try Money.decimal(rate) >= 0 else { throw BudgetError.invalid("Ставка транша не может быть отрицательной.") } }; guard rule.feeMinor >= 0 else { throw BudgetError.invalid("Комиссия не может быть отрицательной.") } }; try unique(terms.credit.buckets.map(\.kind))
                for id in [terms.deposit.payoutAccountID, terms.loan.escrowAccountID].compactMap({ $0 }) { guard id != account.id else { throw BudgetError.invalid("Внешний счёт выплаты должен отличаться от счёта договора.") }; _ = try db.account(id) }
            }
            for row in contract.manualRows { guard row.kind != .scheduledPayment, row.date > contract.start, row.amount.map({ $0 >= 0 }) ?? true, row.components.allSatisfy({ $0.amount >= 0 }) else { throw BudgetError.invalid("Проверьте строки ручного графика.") }; let sum = try row.components.reduce(Int64(0)) { try Money.add($0, $1.amount) }; if let amount = row.amount, !row.components.isEmpty { guard sum == amount else { throw BudgetError.invalid("Компоненты строки не совпадают с общей суммой.") } } }
            guard contract.reminders.paymentOffsets.allSatisfy({ (0...3650).contains($0) }), contract.reminders.maturityOffsets.allSatisfy({ (0...3650).contains($0) }), (0...23).contains(contract.reminders.hour), (0...59).contains(contract.reminders.minute) else { throw BudgetError.invalid("Проверьте интервалы и время напоминаний.") }
            if contract.kind.isDebt {
                // Each replay only needs postings involving its account; references and conditions stay intact.
                var projection = db; projection.operations = debtOperations[account.id] ?? []
                _ = try debt(accountID: account.id, db: projection)
            }
        }
        let operations = Dictionary(uniqueKeysWithValues: db.operations.map { ($0.id, $0) })
        let operationIDs = Set(operations.keys), contractIDs = Set(book.contracts.map(\.id))
        let groups = Dictionary(uniqueKeysWithValues: book.groups.map { ($0.id, $0) })
        var members: [UUID: Set<UUID>] = [:]
        for operation in db.operations { if let groupID = operation.financial?.groupID { members[groupID, default: []].insert(operation.id) } }
        for group in book.groups {
            guard contractIDs.contains(group.contractID), !group.operationIDs.isEmpty, Set(group.operationIDs).count == group.operationIDs.count, Set(group.operationIDs).isSubset(of: operationIDs), members[group.id] == Set(group.operationIDs) else { throw BudgetError.invalid("Финансовая группа неполна.") }
            for id in group.operationIDs { guard operations[id]?.financial?.groupID == group.id else { throw BudgetError.invalid("Связь операции с группой повреждена.") } }
        }
        for o in db.operations {
            if let allocations = o.financial?.statementAllocations, !allocations.isEmpty {
                guard o.kind == .transfer, let target = o.toAccountID, let contract = book.contracts.first(where: { $0.accountID == target }), contract.kind == .revolvingCredit else { throw BudgetError.invalid("Распределение по выпискам применимо только к погашению карты.") }
                try unique(allocations.map(\.statementID))
                for item in allocations {
                    guard item.amount > 0, book.statements.contains(where: { $0.id == item.statementID && $0.contractID == contract.id && $0.closedOn < o.date }) else { throw BudgetError.invalid("Проверьте выписку и положительную сумму распределения.") }
                }
                guard try allocations.reduce(Int64(0), { try Money.add($0, $1.amount) }) <= o.toAmount ?? 0 else { throw BudgetError.invalid("Распределение по выпискам превышает платёж.") }
            }
            if let regular = o.financial?.prepaymentRegularPayment { guard regular > 0 else { throw BudgetError.invalid("Регулярный платёж до досрочного погашения должен быть положительным.") } }
            if let end = o.financial?.prepaymentScheduleEnd { guard end > o.date else { throw BudgetError.invalid("Окончание сохранённого графика должно быть после досрочного платежа.") } }
            if o.financial?.prepaymentMode != nil { guard o.financial?.prepayment == true, db.accounts.first(where: { $0.id == o.toAccountID }).map({ $0.kind == .mortgage || $0.kind == .termLoan }) == true else { throw BudgetError.invalid("Режим досрочного погашения применим к платежу по кредиту / ипотеке.") } }
            if let metadata = o.financial { guard metadata.version == 1, metadata.allocations.allSatisfy({ $0.amount >= 0 && $0.component != .ownFunds }) else { throw BudgetError.corrupt }; if let contractID = metadata.contractID { guard contractIDs.contains(contractID) else { throw BudgetError.invalid("У операции отсутствует договор.") } }; if let groupID = metadata.groupID { guard groups[groupID]?.operationIDs.contains(o.id) == true else { throw BudgetError.invalid("У операции отсутствует финансовая группа.") } } }
        }
        for fulfillment in book.fulfillments { guard fulfillment.amount > 0, contractIDs.contains(fulfillment.contractID), !fulfillment.operationIDs.isEmpty, Set(fulfillment.operationIDs).isSubset(of: operationIDs) else { throw BudgetError.invalid("Подтверждение события не связано с фактами.") } }
        for statement in book.statements { guard contractIDs.contains(statement.contractID), statement.start <= statement.closedOn, statement.dueOn >= statement.closedOn, statement.balance >= 0, statement.minimum >= 0, statement.graceAmount >= 0 else { throw BudgetError.invalid("Некорректная выписка.") } }
    }
}
