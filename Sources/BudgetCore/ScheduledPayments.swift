import Foundation
import CryptoKit

public struct ScheduledPaymentReminder: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var daysBefore: Int?; public var date: Day?
    public var hour = 9; public var minute = 0; public var enabled = true
    public init(daysBefore: Int = 1) { self.daysBefore = daysBefore }
    public init(date: Day, hour: Int = 9, minute: Int = 0) { self.date = date; self.hour = hour; self.minute = minute }
}
public struct ScheduledPaymentAllocation: Codable, Equatable, Sendable {
    public var operationID: UUID; public var sourceAmount: Int64; public var amount: Int64; public var sourceCurrency: String
    public init(operationID: UUID, sourceAmount: Int64, amount: Int64, sourceCurrency: String) { self.operationID = operationID; self.sourceAmount = sourceAmount; self.amount = amount; self.sourceCurrency = sourceCurrency }
}
public struct ScheduledDueChange: Codable, Equatable, Sendable {
    public var from: Day; public var to: Day; public var changedAt = Date()
    public init(from: Day, to: Day) { self.from = from; self.to = to }
}
public struct ScheduledPayment: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var title: String; public var comment: String; public var amount: Int64; public var currency: String; public var dueOn: Day
    public var timeZoneID = TimeZone.current.identifier; public var accountID: UUID?; public var categoryID: UUID?; public var projectID: UUID?
    public var payee = ""; public var contractReference = ""; public var planID: UUID?; public var planName: String?
    public var cancelled = false; public var archived = false; public var originalAmount: Int64?
    public var reminders = [ScheduledPaymentReminder(daysBefore: 7), ScheduledPaymentReminder(daysBefore: 1), ScheduledPaymentReminder(daysBefore: 0)]
    public var allocations: [ScheduledPaymentAllocation] = []; public var dateHistory: [ScheduledDueChange] = []
    public var createdAt = Date(); public var modifiedAt = Date()
    public init(title: String, comment: String, amount: Int64, currency: String, dueOn: Day) { self.title = title; self.comment = comment; self.amount = amount; self.currency = currency; self.dueOn = dueOn }
    public var eventID: String { "scheduled." + id.uuidString.lowercased() }
}
public enum ScheduledPaymentState: String, CaseIterable, Sendable {
    case planned, partial, paid, cancelled, overdue, today
    public var title: String { switch self { case .planned: "Запланирован"; case .partial: "Частично оплачен"; case .paid: "Оплачен"; case .cancelled: "Отменён"; case .overdue: "Просрочен"; case .today: "Сегодня" } }
}
public enum ScheduledPayments {
    public static func paid(_ payment: ScheduledPayment, db: Database) throws -> Int64 {
        // Linked facts are validated on writes; deletion detaches their allocations atomically.
        return try payment.allocations.reduce(0) { try Money.add($0, $1.amount) }
    }
    public static func remaining(_ payment: ScheduledPayment, db: Database) throws -> Int64 { max(0, try Money.add(payment.amount, -paid(payment, db: db))) }
    public static func today(_ payment: ScheduledPayment, now: Date = Date()) -> Day {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: payment.timeZoneID) ?? .current
        let d = c.dateComponents([.year, .month, .day], from: now); return try! Day(String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!))
    }
    public static func state(_ payment: ScheduledPayment, db: Database, now: Date = Date()) throws -> ScheduledPaymentState {
        if payment.cancelled { return .cancelled }; if try remaining(payment, db: db) == 0 { return .paid }
        let localDay = today(payment, now: now)
        if payment.dueOn < localDay { return .overdue }; if try paid(payment, db: db) > 0 { return .partial }; return payment.dueOn == localDay ? .today : .planned
    }
    public static func installments(template: ScheduledPayment, count: Int, weekly: Bool = false) throws -> [ScheduledPayment] {
        guard (1...600).contains(count), template.amount >= Int64(count) else { throw BudgetError.invalid("От 1 до 600 платежей; сумма должна позволять положительную сумму каждого.") }
        if weekly { guard (count - 1) * 7 <= FinanceMath.days(template.dueOn, try Day("9999-12-31")) else { throw BudgetError.invalid("График выходит за пределы поддерживаемого календаря.") } }
        let part = template.amount / Int64(count), planID = UUID()
        return try (0..<count).map { index in
            var item = template; item.id = UUID(); item.planID = count == 1 ? nil : planID; item.planName = count == 1 ? nil : template.title
            item.title = count == 1 ? template.title : template.title + " · \(index + 1)/\(count)"; item.amount = index == count - 1 ? template.amount - part * Int64(count - 1) : part
            item.dueOn = weekly ? template.dueOn.adding(index * 7) : try FinanceMath.addingMonths(template.dueOn, index)
            item.allocations = []; item.dateHistory = []; item.originalAmount = nil; item.reminders = template.reminders.map { var r = $0; r.id = UUID(); return r }; return item
        }
    }
    public static func save(_ payment: ScheduledPayment, in db: inout Database) throws { try save([payment], in: &db) }
    public static func save(_ payments: [ScheduledPayment], in db: inout Database) throws {
        var candidate = db, book = db.financeData
        guard Set(payments.map(\.id)).count == payments.count else { throw BudgetError.conflict("Повторяющиеся позиции плана.") }
        for var payment in payments {
            payment.title = payment.title.trimmingCharacters(in: .whitespacesAndNewlines); payment.comment = payment.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = (book.scheduledPayments ?? []).firstIndex(where: { $0.id == payment.id }) {
                let old = book.scheduledPayments![i]
                guard payment.allocations == old.allocations else { throw BudgetError.conflict("Подтверждайте оплату отдельным действием.") }
                guard old.allocations.isEmpty || old.currency == payment.currency else { throw BudgetError.conflict("У оплаченной позиции нельзя менять валюту.") }
                if try remaining(old, db: db) == 0, old.amount != payment.amount || old.dueOn != payment.dueOn { throw BudgetError.conflict("Оплаченный график сохраняется в истории.") }
                payment.createdAt = old.createdAt; payment.dateHistory = old.dateHistory; payment.originalAmount = old.originalAmount
                if old.dueOn != payment.dueOn { payment.dateHistory.append(ScheduledDueChange(from: old.dueOn, to: payment.dueOn)) }
                payment.modifiedAt = Date(); book.scheduledPayments![i] = payment
            } else {
                guard payment.allocations.isEmpty else { throw BudgetError.conflict("Новая позиция не может содержать оплаты.") }
                if book.scheduledPayments == nil { book.scheduledPayments = [] }; book.scheduledPayments!.append(payment)
            }
        }
        candidate.finances = book; try validate(candidate); db = candidate
    }
    public static func delete(_ id: UUID, in db: inout Database) { db.finances?.scheduledPayments?.removeAll { $0.id == id } }
    public static func detachOperations(_ ids: Set<UUID>, in db: inout Database) {
        guard var book = db.finances, var payments = book.scheduledPayments else { return }
        for i in payments.indices { payments[i].allocations.removeAll { ids.contains($0.operationID) } }; book.scheduledPayments = payments; db.finances = book
    }
    public static func operationChanged(from old: Operation, to new: Operation, in db: inout Database) throws {
        guard var book = db.finances, var payments = book.scheduledPayments else { return }
        let links = payments.indices.flatMap { i in payments[i].allocations.indices.filter { payments[i].allocations[$0].operationID == old.id }.map { (i, $0) } }
        guard !links.isEmpty else { return }; let currency = try db.account(new.accountID).currency
        guard new.kind == .expense, links.allSatisfy({ payments[$0.0].allocations[$0.1].sourceCurrency == currency }) else { throw BudgetError.conflict("Сначала снимите связь планового платежа перед сменой типа или валюты расхода.") }
        guard old.amount != new.amount else { return }
        let total = try links.reduce(Int64(0)) { try Money.add($0, payments[$1.0].allocations[$1.1].sourceAmount) }
        var left = try FinanceMath.rounded(try Money.divide(Money.multiply(Decimal(total), Decimal(new.amount)), Decimal(old.amount)))
        for (position, link) in links.enumerated() {
            let previous = payments[link.0].allocations[link.1]
            let source = position == links.count - 1 ? left : min(left, try FinanceMath.rounded(try Money.divide(Money.multiply(Decimal(previous.sourceAmount), Decimal(new.amount)), Decimal(old.amount))))
            left -= source
            payments[link.0].allocations[link.1].amount = try FinanceMath.rounded(try Money.divide(Money.multiply(Decimal(previous.amount), Decimal(source)), Decimal(previous.sourceAmount)))
            payments[link.0].allocations[link.1].sourceAmount = source
        }
        for i in payments.indices { payments[i].allocations.removeAll { $0.sourceAmount == 0 || $0.amount == 0 } }; book.scheduledPayments = payments; db.finances = book; try validate(db)
    }
    public static func link(_ id: UUID, operationID: UUID, sourceAmount: Int64? = nil, paymentAmount: Int64? = nil, closeRemainder: Bool = false, in db: inout Database) throws {
        var candidate = db, book = db.financeData
        guard let index = book.scheduledPayments?.firstIndex(where: { $0.id == id }), let operation = db.operations.first(where: { $0.id == operationID && $0.kind == .expense }) else { throw BudgetError.missing("Плановый платёж или расход не найден.") }
        let payment = book.scheduledPayments![index]
        guard !payment.cancelled, !payment.archived, try remaining(payment, db: db) > 0 else { throw BudgetError.conflict("Этот платёж уже закрыт или отменён.") }
        guard !payment.allocations.contains(where: { $0.operationID == operationID }) else { throw BudgetError.conflict("Этот расход уже связан с платежом.") }
        let currency = try db.account(operation.accountID).currency
        let used = try (book.scheduledPayments ?? []).flatMap(\.allocations).filter { $0.operationID == operationID }.reduce(0) { try Money.add($0, $1.sourceAmount) }
        let source = sourceAmount ?? (operation.amount - used)
        guard source > 0, try Money.add(used, source) <= operation.amount else { throw BudgetError.invalid("Сумма распределений превышает расход.") }
        let amount: Int64
        if currency == payment.currency { guard paymentAmount == nil || paymentAmount == source else { throw BudgetError.invalid("В одной валюте суммы оплаты должны совпадать.") }; amount = source }
        else { guard let value = paymentAmount, value > 0 else { throw BudgetError.invalid("Укажите фактическую сумму оплаты в валюте обязательства.") }; amount = value }
        book.scheduledPayments![index].allocations.append(ScheduledPaymentAllocation(operationID: operationID, sourceAmount: source, amount: amount, sourceCurrency: currency))
        if closeRemainder { candidate.finances = book; book.scheduledPayments![index].originalAmount = payment.originalAmount ?? payment.amount; book.scheduledPayments![index].amount = try paid(book.scheduledPayments![index], db: candidate) }
        book.scheduledPayments![index].modifiedAt = Date(); candidate.finances = book; try validate(candidate); db = candidate
    }
    public static func pay(_ id: UUID, from accountID: UUID, amount: Int64, paymentAmount: Int64? = nil, date: Day = .today, closeRemainder: Bool = false, in db: inout Database) throws -> Operation {
        guard let payment = db.financeData.scheduledPayments?.first(where: { $0.id == id }) else { throw BudgetError.missing("Плановый платёж не найден.") }
        var candidate = db, operation = Operation(kind: .expense, date: date, accountID: accountID, amount: amount)
        operation.comment = payment.title + " — " + payment.comment; operation.categoryID = payment.categoryID; operation.projectID = payment.projectID
        let currency = try db.account(accountID).currency
        if currency != payment.currency, let paid = paymentAmount { operation.fx = [FXRate(base: currency, quote: payment.currency, rate: try Money.ratio(from: amount, currency: currency, to: paid, toCurrency: payment.currency), date: date, provider: "Фактическая оплата обязательства")] }
        try Ledger.saveOperation(operation, in: &candidate); try link(id, operationID: operation.id, paymentAmount: paymentAmount, closeRemainder: closeRemainder, in: &candidate)
        try Ledger.validate(candidate); db = candidate; return db.operations.first { $0.id == operation.id }!
    }
    public static func unlink(_ id: UUID, operationID: UUID, in db: inout Database) {
        guard let i = db.finances?.scheduledPayments?.firstIndex(where: { $0.id == id }) else { return }; db.finances?.scheduledPayments?[i].allocations.removeAll { $0.operationID == operationID }
    }
    public static func events(db: Database) throws -> [FinanceEvent] {
        try (db.financeData.scheduledPayments ?? []).filter { !$0.cancelled && !$0.archived }.map { p in FinanceEvent(id: p.eventID, contractID: p.id, kind: .scheduledPayment, date: p.dueOn, accrualEnd: p.dueOn, components: [], amount: p.amount, remaining: try remaining(p, db: db), balanceAfter: nil, accuracy: .calculated, notes: [p.title, p.comment]) }
    }
    public static func reminderRequests(db: Database, now: Date, horizon: Date, delivered: Set<String>) throws -> [FinancialReminderRequest] {
        let token = FinancialReminderPlanner.databaseToken(db.id)
        var result: [FinancialReminderRequest] = []
        for p in db.financeData.scheduledPayments ?? [] where !p.cancelled && !p.archived {
            guard try remaining(p, db: db) > 0, let zone = TimeZone(identifier: p.timeZoneID) else { continue }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            for r in p.reminders where r.enabled {
                let day: Day
                if let absolute = r.date { day = absolute }
                else if let offset = r.daysBefore, offset <= FinanceMath.days(try Day("0001-01-01"), p.dueOn) { day = p.dueOn.adding(-offset) }
                else { continue }
                var c = DateComponents(); c.year = FinanceMath.year(day); c.month = FinanceMath.month(day); c.day = FinanceMath.day(day); c.hour = r.hour; c.minute = r.minute; c.timeZone = zone
                guard let date = calendar.date(from: c) else { continue }
                let key = FinancialReminderPlanner.prefix + SHA256.hash(data: Data((token + "|" + p.eventID + "|" + day.rawValue + "|" + String(r.hour) + ":" + String(r.minute) + "|" + zone.identifier).utf8)).map { String(format: "%02x", $0) }.joined()
                let postponed = db.financeData.reminders.eventSnoozedUntil?[p.eventID]
                let fire = db.financeData.reminders.snoozedUntil[key] ?? max(date, postponed ?? date)
                guard fire > now, fire <= horizon, !delivered.contains(key) || postponed != nil || db.financeData.reminders.snoozedUntil[key] != nil else { continue }
                result.append(FinancialReminderRequest(id: key, databaseToken: token, eventToken: p.eventID, fireAt: fire, timeZoneID: zone.identifier))
            }
        }
        return result
    }
    public static func validate(_ db: Database) throws {
        let payments = db.financeData.scheduledPayments ?? []
        guard db.version >= 3 || payments.isEmpty, Set(payments.map(\.id)).count == payments.count else { throw BudgetError.corrupt }
        guard !payments.isEmpty else { return }
        guard Set(payments.map(\.id)).isDisjoint(with: db.financeData.contracts.map(\.id)) else { throw BudgetError.corrupt }
        let operations = Dictionary(uniqueKeysWithValues: db.operations.map { ($0.id, $0) }); var sourceUsed: [UUID: Int64] = [:]
        for p in payments {
            guard !Ledger.normalized(p.title).isEmpty, !Ledger.normalized(p.comment).isEmpty else { throw BudgetError.invalid("Название платежа и комментарий обязательны.") }
            guard p.amount > 0, p.originalAmount.map({ $0 > 0 }) ?? true, TimeZone(identifier: p.timeZoneID) != nil else { throw BudgetError.invalid("Нужны положительная сумма и корректный часовой пояс.") }; _ = try Currency.get(p.currency)
            if let id = p.accountID { _ = try db.account(id) }; if let id = p.categoryID { guard db.categories.contains(where: { $0.id == id && $0.kind == .expense }) else { throw BudgetError.invalid("Категория расхода не найдена.") } }
            if let id = p.projectID { guard db.projects.contains(where: { $0.id == id }) else { throw BudgetError.invalid("Проект не найден.") } }
            guard p.planID == nil || p.planName.map({ !Ledger.normalized($0).isEmpty }) == true, Set(p.reminders.map(\.id)).count == p.reminders.count, p.reminders.count <= 60 else { throw BudgetError.invalid("Проверьте название плана и напоминания (до 60).") }
            for r in p.reminders { guard (0...23).contains(r.hour), (0...59).contains(r.minute), (r.daysBefore == nil) != (r.date == nil), r.daysBefore.map({ (0...36600).contains($0) }) ?? true else { throw BudgetError.invalid("Проверьте дату, отступ и время напоминания.") } }
            guard Set(p.allocations.map(\.operationID)).count == p.allocations.count else { throw BudgetError.conflict("Повторное распределение одного расхода.") }
            for a in p.allocations {
                guard let o = operations[a.operationID], o.kind == .expense, a.sourceAmount > 0, a.amount > 0, try db.account(o.accountID).currency == a.sourceCurrency else { throw BudgetError.corrupt }
                if a.sourceCurrency == p.currency { guard a.sourceAmount == a.amount else { throw BudgetError.corrupt } }; sourceUsed[o.id] = try Money.add(sourceUsed[o.id] ?? 0, a.sourceAmount)
            }; _ = try paid(p, db: db)
        }
        for (id, amount) in sourceUsed { guard amount <= operations[id]!.amount else { throw BudgetError.invalid("Сумма распределений превышает фактический расход.") } }
    }
}
