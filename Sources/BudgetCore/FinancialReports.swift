import Foundation

public enum FinancialReports {
    public static func rows(_ report: Report, db: Database, asOf: Day = .today) throws -> [ReportRow] {
        let accounts = db.accounts.filter { ($0.kind != .ordinary) && (report.filters.accounts.isEmpty || report.filters.accounts.contains($0.id)) && (report.filters.currency == nil || report.filters.currency == $0.currency) }
        // Existing debt and obligations remain visible for archived accounts.
        if report.dataset == .debt {
            let end = min(report.filters.end ?? asOf, asOf)
            if report.grouping == .account { return try accounts.filter { $0.kind.isDebt && $0.openedOn <= end }.map { account in
                let summary = try FinancialLedger.debt(accountID: account.id, db: db, on: end)
                let amount = report.metric == .principal ? summary.amount(.principal) : report.metric == .interest ? summary.amount(.interest) : report.metric == .fees ? try Money.add(summary.amount(.fee), summary.amount(.penalty)) : summary.debt
                let complete = ![Metric.principal, .interest, .fees].contains(report.metric) || summary.amount(.unallocated) == 0
                var row = ReportRow(id: account.id.uuidString, title: account.name, value: try valuation(amount, account: account, report: report, date: end, db: db, complete: complete)); row.accountIDs = [account.id]; return row
            } }
            var day = report.filters.start ?? end.firstOfMonth, result: [ReportRow] = []
            while day <= end {
                try Task.checkCancellation()
                let point = report.grouping == .month ? min(day.lastOfMonth, end) : day
                var probe = report; probe.grouping = .account; probe.filters.end = point
                let parts = try rows(probe, db: db, asOf: asOf)
                var row = ReportRow(id: report.grouping == .month ? day.month : day.rawValue, title: report.grouping == .month ? day.month : day.rawValue, value: try Reports.total(parts)); row.accountIDs = parts.flatMap(\.accountIDs); result.append(row)
                day = point.adding(1); guard result.count <= 36600 else { throw BudgetError.invalid("Сократите период финансового отчёта.") }
            }
            return result
        }
        let allowed = Set(accounts.map(\.id))
        var grouped: [String: ReportRow] = [:]
        for contract in db.financeData.contracts where allowed.contains(contract.accountID) && contract.status == .active {
            try Task.checkCancellation()
            let account = try db.account(contract.accountID)
            let events = try FinancialEngine.events(contract: contract, db: db, asOf: asOf)
            for event in events where !event.isFulfilled && (report.filters.start == nil || event.date >= report.filters.start!) && (report.filters.end == nil || event.date <= report.filters.end!) {
                let amount: Int64?
                var complete = event.accuracy == .calculated
                if report.dataset == .depositYield {
                    guard event.kind == .depositInterest || event.kind == .tax && report.metric == .netYield else { continue }
                    if report.metric == .netYield {
                        if event.kind == .tax { amount = event.remaining.map { -$0 } }
                        else if contract.terms(on: event.accrualEnd)?.deposit.separateTaxFrequency != nil { amount = event.remaining }
                        else {
                        if let gross = event.remaining, let terms = contract.terms(on: event.accrualEnd), terms.deposit.taxKnown {
                            let tax = try terms.deposit.taxAmount ?? terms.deposit.taxPercent.map { try FinanceMath.rounded(Decimal(gross) * Money.decimal($0) / 100, mode: terms.rounding) } ?? 0
                            amount = gross - tax
                        } else { amount = nil; complete = false }
                        }
                    } else { amount = event.remaining }
                } else {
                    let types: [FinanceEventKind] = report.metric == .grace ? [.gracePayment] : [.loanPayment, .minimumPayment, .insurance, .tax]
                    guard types.contains(event.kind) else { continue }
                    amount = event.remaining
                }
                let key = report.grouping == .account ? account.id.uuidString : report.grouping == .month ? event.date.month : event.date.rawValue
                var row = grouped[key] ?? ReportRow(id: key, title: report.grouping == .account ? account.name : key)
                let value = try valuation(amount, account: account, report: report, date: event.date, db: db, complete: complete)
                row.value.known = try Money.add(row.value.known, value.known); row.value.missing += value.missing; row.value.missingConditions += value.missingConditions; row.value.currencies.formUnion(value.currencies); row.value.count += 1
                if !row.accountIDs.contains(account.id) { row.accountIDs.append(account.id) }
                grouped[key] = row
            }
        }
        return grouped.values.sorted { $0.id < $1.id }
    }
    private static func valuation(_ amount: Int64?, account: Account, report: Report, date: Day, db: Database, complete: Bool = true) throws -> Valuation {
        var value = Valuation(); value.count = 1
        if !complete || amount == nil { value.missingConditions = [account.id] }
        if let amount, let rate = try Reports.rate(from: account.currency, to: report.currency, rates: db.rates, on: min(date, .today)) {
            value.known = try Money.convert(amount, from: account.currency, to: report.currency, rate: rate)
        } else if try Reports.rate(from: account.currency, to: report.currency, rates: db.rates, on: min(date, .today)) == nil { value.missing = [account.id]; value.currencies = [account.currency] }
        return value
    }
}
