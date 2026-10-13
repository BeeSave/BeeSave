import Foundation

public enum PlanningLedger {
    public static func migrate(_ old: Database) throws -> Database {
        guard (1...4).contains(old.version) else { throw BudgetError.newerVersion }
        if old.version == 4 { return old }
        var db = try FinancialLedger.migrate(old); db.version = 4
        for index in db.projects.indices where db.projects[index].details == nil {
            var details = ProjectDetails(); details.currency = db.settings.baseCurrency; details.migrated = true
            if let budget = db.budgets.last(where:{ $0.kind == .project && $0.projectID == db.projects[index].id && !$0.completed }) { details.currency = budget.currency; details.target = budget.limit; details.dueOn = budget.end }
            db.projects[index].details = details
        }
        try validate(db); return db
    }
    public static func saveFlow(_ flow: PlanFlow, in db: inout Database) throws {
        var candidate = db, book = db.planningData
        if let i = book.flows.firstIndex(where: { $0.id == flow.id }) {
            let old = book.flows[i]; var saved = flow
            guard old.history == flow.history else { throw BudgetError.conflict("Прежние условия серии нельзя переписывать.") }
            if old != flow {
                if old.start < .today || book.allocations.contains(where:{ $0.occurrenceID.hasPrefix(flow.id.uuidString.lowercased() + ".") }) { guard old.start == flow.start,old.frequency == flow.frequency else { throw BudgetError.conflict("Начатую серию не сдвигают целиком. Используйте исключение для вхождения или новую серию.") } }
                if book.allocations.contains(where:{ $0.occurrenceID.hasPrefix(flow.id.uuidString.lowercased() + ".") }) {
                    guard old.currency == flow.currency,old.purpose == flow.purpose else { throw BudgetError.conflict("Для другой валюты/направления после факта создайте новую серию.") }
                }
                var snapshot = old; snapshot.history = nil
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let version = PlanFlowVersion(validUntil:.today.adding(-1),snapshot:try encoder.encode(snapshot))
                saved.history = old.history ?? []; if !saved.history!.contains(where:{ $0.validUntil == version.validUntil }) { saved.history!.append(version) }
            }
            book.flows[i] = saved
        } else { book.flows.append(flow) }
        candidate.planningData = book; try validate(candidate); db = candidate
    }
    public static func saveGoal(_ goal: SavingsGoal, in db: inout Database) throws {
        var candidate = db, book = db.planningData
        let old = book.goals.first { $0.id == goal.id }
        if let i = book.goals.firstIndex(where: { $0.id == goal.id }) { book.goals[i] = goal } else { book.goals.append(goal) }
        if let accountID = goal.accountID,old == nil || goal.allocated > old!.allocated || goal.accountID != old!.accountID {
            let reserved = try book.goals.filter { $0.accountID == accountID }.reduce(Int64(0)) { try Money.add($0,$1.allocated) }
            guard reserved <= max(0,try db.balance(accountID)) else { throw BudgetError.conflict("Одни средства нельзя выделить нескольким целям сверх остатка.") }
        }
        candidate.planningData = book; try validate(candidate); db = candidate
    }
    public static func saveProject(_ project: Project, in db: inout Database) throws {
        var candidate = db
        if let old = db.projects.first(where: { $0.id == project.id })?.details {
            if !old.facts.isEmpty || !old.versions.isEmpty || db.operations.contains(where:{ $0.projectID == project.id }) { guard old.currency == project.details?.currency else { throw BudgetError.conflict("После фактов/утверждения валюту проекта не меняют.") } }
            guard old.versions.allSatisfy({ project.details?.versions.contains($0) == true }) else { throw BudgetError.conflict("Утверждённые версии плана нельзя переписывать.") }
        }
        try Ledger.saveProject(project, in: &candidate); try validate(candidate); db = candidate
    }
    public static func approveProject(_ id: UUID, reason: String, in db: inout Database) throws {
        try Ledger.nonempty(reason); guard let i = db.projects.firstIndex(where: { $0.id == id }), var details = db.projects[i].details else { throw BudgetError.missing("Проект не найден.") }
        details.versions.append(ProjectPlanVersion(reason: reason, details: details))
        var project = db.projects[i]; project.details = details; try saveProject(project, in: &db)
    }
    public static func allocate(_ allocation: PlanAllocation, in db: inout Database) throws {
        var candidate = db, book = db.planningData
        guard !book.allocations.contains(where: { $0.id == allocation.id }) else { throw BudgetError.conflict("Связь уже существует.") }
        book.allocations.append(allocation); candidate.planningData = book; try validate(candidate); db = candidate
    }
    public static func operationChanged(from old: Operation, to new: Operation, in db: inout Database) throws {
        guard db.planning != nil || db.projects.contains(where:{ $0.details != nil }) else { return }
        let currencyChanged = try db.account(old.accountID).currency != db.account(new.accountID).currency
        if old.kind != new.kind || currencyChanged { detach([old.id],in:&db); return }
        if old.amount != new.amount {
            let selected = db.planningData.allocations.filter { $0.operationID == old.id }.sorted { $0.id.uuidString < $1.id.uuidString }
            let total = try selected.reduce(Int64(0)) { try Money.add($0,$1.amount) }
            let target = try FinanceMath.rounded(Money.divide(Money.multiply(Decimal(total),Decimal(new.amount)),Decimal(old.amount)),mode:.truncate)
            var assigned: Int64 = 0
            for (index,a) in selected.enumerated() {
                let part = index == selected.count - 1 ? target - assigned : min(target-assigned,try FinanceMath.rounded(Money.divide(Money.multiply(Decimal(a.amount),Decimal(new.amount)),Decimal(old.amount)),mode:.truncate))
                assigned = try Money.add(assigned,part)
                if let i = db.planning!.allocations.firstIndex(where:{ $0.id == a.id }) { db.planning!.allocations[i].amount = part; db.planning!.allocations[i].sourceAmount = part }
            }
            db.planning?.allocations.removeAll { $0.amount == 0 }
        }
        for i in db.projects.indices {
            guard var d = db.projects[i].details else { continue }
            for j in d.facts.indices where d.facts[j].operationID == new.id {
                if old.amount != new.amount { d.facts[j].amount = try FinanceMath.rounded(Money.divide(Money.multiply(Decimal(d.facts[j].amount),Decimal(new.amount)),Decimal(old.amount)),mode:.truncate) }
                d.facts[j].date = new.date
            }
            d.facts.removeAll { $0.amount == 0 }; db.projects[i].details = d
        }
    }
    public static func detach(_ ids: Set<UUID>, in db: inout Database) {
        guard db.planning != nil else { return }
        db.planning?.allocations.removeAll { ids.contains($0.operationID) }
        for i in db.projects.indices { db.projects[i].details?.facts.removeAll { $0.operationID.map(ids.contains) == true } }
        for i in db.planning!.taxes.indices where db.planning!.taxes[i].refundOperationID.map(ids.contains) == true {
            db.planning!.taxes[i].refundOperationID = nil; db.planning!.taxes[i].stage = .approved
        }
    }
    public static func validate(_ db: Database) throws {
        guard db.version >= 4 || (db.planning == nil && db.operations.allSatisfy({ $0.reconciliation == nil }) && db.projects.allSatisfy({ $0.details == nil })) else { throw BudgetError.corrupt }
        let book = db.planningData
        _ = try IncomeDistribution.calculate(netIncome:book.distributionIncome,rules:book.allocationRules)
        func unique<T>(_ values: [T], _ key: (T) -> UUID) throws { guard Set(values.map(key)).count == values.count else { throw BudgetError.corrupt } }
        try unique(book.flows, { $0.id }); try unique(book.goals, { $0.id }); try unique(book.allocations, { $0.id }); try unique(book.taxes, { $0.id }); try unique(book.scenarios, { $0.id })
        guard book.reserve >= 0 else { throw BudgetError.invalid("Резерв не может быть отрицательным.") }; _ = try Currency.get(book.reserveCurrency)
        let accounts = Dictionary(uniqueKeysWithValues: db.accounts.map { ($0.id,$0) }), projects = Set(db.projects.map(\.id)), categories = Dictionary(uniqueKeysWithValues: db.categories.map { ($0.id,$0) })
        for account in db.accounts { if let id = account.businessProjectID { guard db.projects.first(where:{ $0.id == id })?.details?.type == .business else { throw BudgetError.invalid("Счёт компании требует бизнес-проект.") } } }
        for flow in book.flows {
            guard flow.purpose == .living || flow.exceptions.allSatisfy({ !$0.closed }) else { throw BudgetError.invalid("Закрыть неиспользованный лимит можно только для повседневных расходов. Обязательный платёж подтверждают фактом или явно отменяют.") }
            if let parentID = flow.parentFlowID {
                guard let parent = book.flows.first(where:{ $0.id == parentID }),parent.id != flow.id,parent.parentFlowID == nil,parent.purpose == .living,parent.frequency == .monthly,flow.frequency == .monthly,flow.purpose != .income,parent.currency == flow.currency,flow.scheduledPaymentID == nil,flow.financeEventID == nil else { throw BudgetError.invalid("Вложенный расход требует отдельный месячный лимит жизни в той же валюте; циклы недопустимы.") }
                let children = book.flows.filter { $0.parentFlowID == parentID && $0.enabled }
                if let total = parent.amount,children.allSatisfy({ $0.amount != nil }) { guard try children.reduce(Int64(0),{ try Money.add($0,$1.amount!) }) <= total else { throw BudgetError.conflict("Включённые строки превышают общий лимит жизни.") } }
            }
            for version in flow.history ?? [] {
                guard version.snapshot.count <= 1_048_576 else { throw BudgetError.corrupt }
                let old = try JSONDecoder().decode(PlanFlow.self,from:version.snapshot)
                guard old.id == flow.id,old.history == nil else { throw BudgetError.corrupt }
            }
            try Ledger.nonempty(flow.title); _ = try Currency.get(flow.currency)
            guard flow.amount == nil || flow.amount! > 0, flow.end == nil || flow.end! >= flow.start else { throw BudgetError.invalid("План требует положительную сумму и корректный срок.") }
            guard Set(flow.exceptions.map(\.anchor)).count == flow.exceptions.count, Set(flow.dates).count == flow.dates.count else { throw BudgetError.conflict("Повторяющиеся даты или исключения плана.") }
            if let id = flow.accountID { guard accounts[id]?.currency == flow.currency else { throw BudgetError.invalid("Валюта плана должна совпадать с валютой предполагаемого счёта.") } }
            if let id = flow.projectID { guard projects.contains(id) else { throw BudgetError.missing("Проект плана не найден.") } }
            if let id = flow.categoryID { guard categories[id]?.kind == (flow.purpose == .income ? .income : .expense) else { throw BudgetError.invalid("Категория не соответствует направлению плана.") } }
            for e in flow.exceptions { guard e.amount == nil || e.amount! > 0 else { throw BudgetError.invalid("Неверная сумма исключения.") } }
            if let id = flow.scheduledPaymentID { guard (db.financeData.scheduledPayments ?? []).contains(where: { $0.id == id }) else { throw BudgetError.missing("Связанный платёж не найден.") } }
        }
        var allocated: [UUID:Int64] = [:]
        for a in book.allocations {
            guard a.amount > 0, a.sourceAmount > 0, let op = db.operations.first(where: { $0.id == a.operationID }), op.kind.isFlow,
                  let flow = book.flows.first(where: { a.occurrenceID.hasPrefix($0.id.uuidString.lowercased() + ".") }), op.kind == (flow.purpose == .income ? .income : .expense),
                  try db.account(op.accountID).currency == flow.currency, a.amount == a.sourceAmount, try PlanningEngine.validAnchor(flow:flow,occurrenceID:a.occurrenceID) else { throw BudgetError.invalid("Неверная связь факта с планом; межвалютную оплату свяжите через финансовое обязательство.") }
            allocated[op.id] = try Money.add(allocated[op.id] ?? 0,a.sourceAmount)
            guard allocated[op.id]! <= op.amount else { throw BudgetError.invalid("Распределение превышает сумму факта. Уточните связи перед изменением операции.") }
        }
        var reservedByAccount: [UUID:Int64] = [:]
        for goal in book.goals {
            try Ledger.nonempty(goal.title); _ = try Currency.get(goal.currency)
            guard goal.target > 0, goal.allocated >= 0, goal.monthly >= 0 else { throw BudgetError.invalid("Проверьте сумму цели и накопления.") }
            if let id = goal.projectID { guard projects.contains(id) else { throw BudgetError.missing("Проект цели не найден.") } }
            if let id = goal.accountID {
                guard accounts[id]?.kind.isDebt == false, accounts[id]?.businessProjectID == nil, accounts[id]?.currency == goal.currency else { throw BudgetError.invalid("Цель требует собственный счёт в той же валюте.") }
                reservedByAccount[id] = try Money.add(reservedByAccount[id] ?? 0,goal.allocated)
                // Actual spending may breach a reservation; recording a fact must remain possible.
            }
        }
        var linkedPayments = Set<UUID>(), linkedFlows = Set<UUID>()
        for project in db.projects { if let d = project.details {
            _ = try Currency.get(d.currency); guard d.target >= 0, d.reserve >= 0 else { throw BudgetError.invalid("Неверные суммы проекта.") }
            try unique(d.costs, { $0.id }); try unique(d.participants, { $0.id }); try unique(d.facts, { $0.id }); try unique(d.versions, { $0.id })
            let parties = Set(d.participants.map(\.id)), costs = Set(d.costs.map(\.id)); var percent = Decimal(0)
            let paymentLinks = d.costs.compactMap(\.scheduledPaymentID),flowLinks = d.costs.compactMap(\.flowID)
            guard Set(paymentLinks).count == paymentLinks.count,Set(flowLinks).count == flowLinks.count else { throw BudgetError.conflict("Один платёж/поток нельзя включить в смету дважды.") }
            for cost in d.costs {
                if let id = cost.scheduledPaymentID { guard linkedPayments.insert(id).inserted else { throw BudgetError.conflict("Одно обязательство нельзя целиком привязать к нескольким проектам.") } }
                if let id = cost.flowID { guard linkedFlows.insert(id).inserted else { throw BudgetError.conflict("Один поток нельзя целиком привязать к нескольким проектам.") } }
                if let id = cost.scheduledPaymentID { guard let payment = (db.financeData.scheduledPayments ?? []).first(where:{ $0.id == id }),payment.currency == d.currency,payment.amount == cost.amount,payment.projectID == nil || payment.projectID == project.id else { throw BudgetError.invalid("Позиция должна совпадать с суммой/валютой связанного обязательства и его проектом.") } }
                if let id = cost.flowID { guard let flow = book.flows.first(where:{ $0.id == id }),flow.currency == d.currency,flow.amount == cost.amount else { throw BudgetError.invalid("Позиция должна совпадать с плановым потоком.") } }
            }
            for p in d.participants {
                try Ledger.nonempty(p.name); guard p.promised >= 0 else { throw BudgetError.invalid("Вклад не может быть отрицательным.") }
                for value in [p.ownershipPercent,p.incomePercent].compactMap({ $0 }) { let v = try Money.decimal(value); guard v >= 0 && v <= 100 else { throw BudgetError.invalid("Доля должна быть от 0 до 100%.") } }
                percent += try p.incomePercent.map(Money.decimal) ?? 0
            }
            guard percent <= 100, d.participants.filter(\.isUser).count <= 1 else { throw BudgetError.invalid("Проверьте участников и распределение дохода.") }
            for c in d.costs {
                try Ledger.nonempty(c.title); let quantityValid = try c.quantity.map { try Money.decimal($0) > 0 } ?? true; guard c.amount >= 0, c.participantID == nil || parties.contains(c.participantID!), quantityValid else { throw BudgetError.invalid("Неверная позиция сметы.") }
            }
            var reimbursements: [UUID:Int64] = [:]
            var usedFacts = Set<UUID>(); var assigned: [UUID:Int64] = [:]
            for fact in d.facts {
                guard fact.amount > 0, fact.date <= .today, fact.participantID == nil || parties.contains(fact.participantID!), fact.costID == nil || costs.contains(fact.costID!) else { throw BudgetError.invalid("Неверный факт проекта.") }
                if let paymentID = fact.reimbursementPaymentID {
                    guard fact.effectiveKind == .expense,fact.operationID == nil,let payment = (db.financeData.scheduledPayments ?? []).first(where:{ $0.id == paymentID }),payment.currency == d.currency else { throw BudgetError.invalid("Возмещение требует внешнюю затрату и отдельный платёж в валюте проекта.") }
                    reimbursements[paymentID] = try Money.add(reimbursements[paymentID] ?? 0,fact.amount)
                }
                if let id = fact.operationID {
                    guard let op = db.operations.first(where: { $0.id == id }), op.kind == (fact.income ? .income : .expense), usedFacts.insert(id).inserted, try db.account(op.accountID).currency == d.currency else { throw BudgetError.invalid("Повторная/неверная операция проекта.") }
                    assigned[id] = try Money.add(assigned[id] ?? 0,fact.amount); guard assigned[id]! <= op.amount else { throw BudgetError.invalid("Проектное распределение превышает факт.") }
                }
            }
            for (id,amount) in reimbursements { guard let payment = (db.financeData.scheduledPayments ?? []).first(where:{ $0.id == id }),payment.amount <= amount else { throw BudgetError.invalid("Возмещение превышает прямую оплату участника.") } }
            if let loan = d.loan {
                guard loan.principal >= 0, loan.downPayment >= 0, (1...600).contains(loan.months), try Money.decimal(loan.annualPercent) >= 0 else { throw BudgetError.invalid("Проверьте условия займа.") }
                if let id = loan.contractID { guard db.financeData.contracts.contains(where: { $0.id == id && $0.kind.isDebt }) else { throw BudgetError.missing("Договор займа не найден.") } }
                for p in loan.prepayments { guard p.amount > 0 else { throw BudgetError.invalid("Досрочный платёж должен быть положительным.") } }
            }
        } }
        for profile in book.taxes {
            _ = try CountryModules.calculate(profile, revision: db.revision ?? 0)
            if let id = profile.refundOperationID { guard db.operations.contains(where: { $0.id == id && $0.kind == .income }) else { throw BudgetError.missing("Факт возврата налога не найден.") } }
        }
        guard (book.eventSettings.priorityOverrides ?? [:]).allSatisfy({ ["payment","deposit","deficit","project","tax"].contains($0.key) && (0...3).contains($0.value) }) else { throw BudgetError.invalid("Проверьте важность типов событий.") }
        guard (0...365).contains(book.eventSettings.paymentDays), (0...365).contains(book.eventSettings.depositDays), (0...365).contains(book.eventSettings.deficitDays) else { throw BudgetError.invalid("Окно событий должно быть от 0 до 365 дней.") }
    }
}
