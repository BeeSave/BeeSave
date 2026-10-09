import Foundation

public enum DashboardCurrencySelection {
    public static let limit = 5
    public static func validate(_ codes: [String], baseCurrency: String? = nil) throws {
        guard codes.count <= limit else { throw BudgetError.invalid("На Главной можно показать не более 5 валют.") }
        guard Set(codes).count == codes.count else { throw BudgetError.invalid("Валюта уже выбрана.") }
        for code in codes { _ = try Currency.get(code) }
        if let baseCurrency, codes.contains(baseCurrency) { throw BudgetError.invalid("Основная валюта не показывается в списке курсов на Главной.") }
    }
    public static func requestedCurrencies(_ db: Database) -> Set<String> {
        Set(db.accounts.map(\.currency) + db.settings.selectedDashboardCurrencies + ["USD", "GBP", db.settings.baseCurrency])
            .subtracting([db.settings.baseCurrency])
    }
}

public struct ResolvedRate: Equatable, Sendable {
    public var value: String
    public var date: Day?
    public var provider: String?
    public func stale(on day: Day = .today) -> Bool { date.map { $0 < day.adding(-7) } ?? false }
}

public struct AccountBalanceRow: Identifiable, Equatable, Sendable {
    public var id: UUID { account.id }
    public var account: Account
    public var amount: Int64
    public var value: Valuation
    public var rate: ResolvedRate?
    public var reportRow: ReportRow {
        var row = ReportRow(id: id.uuidString, title: account.name, value: value)
        row.accountIDs = [id]; return row
    }
}

extension Reports {
    /// One pass over postings keeps the dashboard linear in the size of the ledger.
    public static func accountBalances(_ db: Database, filters: Filters, currency: String, day: Day = .today) throws -> [AccountBalanceRow] {
        var amounts: [UUID: Int64] = [:]
        for operation in db.operations where operation.date <= day {
            amounts[operation.accountID] = try Money.add(amounts[operation.accountID] ?? 0, operation.posting(for: operation.accountID))
            if let to = operation.toAccountID { amounts[to] = try Money.add(amounts[to] ?? 0, operation.posting(for: to)) }
        }
        return try db.accounts.filter {
            (filters.accounts.isEmpty || filters.accounts.contains($0.id)) && (filters.includeArchived || !$0.archived)
                && (filters.currency == nil || filters.currency == $0.currency) && $0.openedOn <= day
        }.map { account in
            let amount = amounts[account.id] ?? 0
            let rate = try resolvedRate(from: account.currency, to: currency, rates: db.rates, on: day)
            var value = Valuation(); value.count = 1
            if let rate { value.known = try Money.convert(amount, from: account.currency, to: currency, rate: rate.value) }
            else { value.missing = [account.id]; value.currencies = [account.currency] }
            return AccountBalanceRow(account: account, amount: amount, value: value, rate: rate)
        }
    }
}
