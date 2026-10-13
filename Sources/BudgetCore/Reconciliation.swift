import Foundation

public enum ReconciliationMode: String, Codable, CaseIterable, Sendable {
    case adjustment, expense, income
    public var title: String { switch self { case .adjustment: "Только корректировка"; case .expense: "Записать расход"; case .income: "Записать доход" } }
}
public struct ReconciliationSource: Codable, Equatable, Sendable {
    public var currency: String?
    public var balance: Int64; public var observed: Int64; public var delta: Int64
    public var date: Day; public var reason: String; public var revision: UInt64
    public init(balance: Int64, observed: Int64, delta: Int64, date: Day, reason: String, revision: UInt64, currency: String? = nil) {
        self.currency = currency; self.balance = balance; self.observed = observed; self.delta = delta; self.date = date; self.reason = reason; self.revision = revision
    }
}
public enum Reconciliation {
    public static func save(accountID: UUID, observed: Int64, reason: String, mode: ReconciliationMode,
                            categoryID: UUID? = nil, projectID: UUID? = nil, budgetMode: BudgetMode = .automatic,
                            expectedRevision: UInt64, in db: inout Database) throws -> Operation? {
        guard (db.revision ?? 0) == expectedRevision else { throw BudgetError.conflict("Остаток изменился. Проверьте новую разницу и подтвердите сверку ещё раз.") }
        let account = try db.account(accountID)
        guard !account.archived else { throw BudgetError.invalid("Для сверки верните счёт из архива.") }
        let balance = try db.balance(accountID), (delta, overflow) = observed.subtractingReportingOverflow(balance)
        guard !overflow else { throw BudgetError.overflow }; guard delta != 0 else { return nil }
        try Ledger.nonempty(reason)
        if mode == .adjustment { return try Ledger.reconcile(accountID: accountID, observed: observed, reason: reason, in: &db) }
        guard account.kind == .ordinary else { throw BudgetError.invalid("Для финансового счёта используйте сверку договора: тело долга или вклада не является доходом/расходом.") }
        guard mode == (delta < 0 ? .expense : .income) else { throw BudgetError.invalid("Способ учёта не соответствует направлению разницы.") }
        var operation = Operation(kind: delta < 0 ? .expense : .income, accountID: accountID, amount: try FinanceMath.positiveMagnitude(delta))
        operation.categoryID = categoryID ?? db.categories.first { $0.kind == operation.kind && $0.system }?.id
        operation.projectID = projectID; operation.budgetMode = budgetMode; operation.comment = reason
        operation.reconciliation = ReconciliationSource(balance: balance, observed: observed, delta: delta, date: .today, reason: reason, revision: expectedRevision, currency: account.currency)
        try Ledger.saveOperation(operation, in: &db); return operation
    }
    public static func validate(_ source: ReconciliationSource) throws {
        if let currency = source.currency { _ = try Currency.get(currency) }
        let (delta, overflow) = source.observed.subtractingReportingOverflow(source.balance)
        guard !overflow, delta == source.delta, delta != 0, source.date <= .today,
              !source.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BudgetError.corrupt }
    }
}
