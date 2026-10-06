import Foundation

struct CreditStatementReceipt {
    var operation: Operation
    var amount: Int64
}

enum CreditStatements {
    /// Effective posting affects a scenario, never the stored ledger facts.
    static func postingDay(_ payment: Operation, contract: FinancialContract, db: Database) throws -> Day? {
        guard let cutoff = contract.cutoffHour else { return payment.date }
        guard let instant = payment.financial?.creditedAt, let zone = TimeZone(identifier: contract.timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let local = calendar.dateComponents([.year, .month, .day, .hour], from: instant)
        let day = try Day(String(format: "%04d-%02d-%02d", local.year!, local.month!, local.day!))
        guard local.hour! >= cutoff else { return day }
        switch contract.lateCreditPosting {
        case .sameDay: return day
        case .nextDay: return day.adding(1)
        case .nextBusinessDay:
            guard let bankCalendar = db.financeData.calendars.first(where: { $0.id == contract.calendarID }) else { return nil }
            let shifted = try FinanceMath.shifted(day.adding(1), rule: .following, calendar: bankCalendar)
            return shifted.1 ? shifted.0 : nil
        case nil: return nil
        }
    }

    /// A receipt is consumed once across statements; minimum and grace within one statement share it.
    static func receipts(statements: [CreditStatement], contract: FinancialContract, db: Database, asOf: Day) throws -> (byStatement: [UUID: [CreditStatementReceipt]], ambiguous: Set<UUID>) {
        var result: [UUID: [CreditStatementReceipt]] = [:], ambiguous = Set<UUID>(), assigned: [UUID: Int64] = [:]
        let payments = db.operations.filter { $0.kind == .transfer && $0.toAccountID == contract.accountID && $0.date <= asOf }
            .sorted { $0.date == $1.date ? ($0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt) : $0.date < $1.date }
        for payment in payments {
            var available = payment.toAmount ?? 0
            let candidates = statements.filter { payment.date > $0.closedOn }
            let manual = payment.financial?.statementAllocations ?? []
            if !manual.isEmpty {
                for item in manual {
                    guard candidates.contains(where: { $0.id == item.statementID }), item.amount > 0, item.amount <= available else { throw BudgetError.invalid("Проверьте распределение платежа по выпискам.") }
                    result[item.statementID, default: []].append(CreditStatementReceipt(operation: payment, amount: item.amount))
                    assigned[item.statementID] = try Money.add(assigned[item.statementID] ?? 0, item.amount); available -= item.amount
                }
                // Unassigned money may be a payment against purchases of the next cycle.
                continue
            }
            if let eventID = payment.financial?.eventID, let selected = candidates.first(where: {
                let anchor = $0.source == "Расчёт BeeSave" ? $0.closedOn.rawValue : $0.id.uuidString
                return [FinanceEventKind.minimumPayment, .gracePayment].contains { FinancialEngine.eventKey(contract.id, kind: $0, anchor: anchor) == eventID }
            }) {
                result[selected.id, default: []].append(CreditStatementReceipt(operation: payment, amount: available))
                assigned[selected.id] = try Money.add(assigned[selected.id] ?? 0, available); continue
            }
            let order = contract.terms(on: payment.date)?.credit.statementPaymentOrder ?? .manual
            if candidates.count > 1 && order == .manual { ambiguous.formUnion(candidates.map(\.id)); continue }
            let sorted = candidates.sorted { $0.closedOn == $1.closedOn ? $0.id.uuidString < $1.id.uuidString : order == .newestFirst ? $0.closedOn > $1.closedOn : $0.closedOn < $1.closedOn }
            for statement in sorted where available > 0 {
                let outstanding = max(0, max(statement.graceAmount, statement.minimum) - (assigned[statement.id] ?? 0))
                let amount = min(available, outstanding)
                if amount > 0 {
                    result[statement.id, default: []].append(CreditStatementReceipt(operation: payment, amount: amount))
                    assigned[statement.id] = try Money.add(assigned[statement.id] ?? 0, amount); available -= amount
                }
            }
        }
        return (result, ambiguous)
    }
}
