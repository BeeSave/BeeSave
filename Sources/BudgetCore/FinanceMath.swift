import Foundation

public enum FinanceMath {
    public static func rounded(_ amount: Decimal, mode: FinanceRounding = .halfUp) throws -> Int64 {
        guard !amount.isNaN else { throw BudgetError.overflow }
        var value = amount, result = Decimal()
        let rounding: Decimal.RoundingMode = mode == .halfEven ? .bankers : mode == .truncate ? (amount < 0 ? .up : .down) : .plain
        NSDecimalRound(&result, &value, 0, rounding)
        return try Money.integer(result)
    }
    public static func positiveMagnitude(_ value: Int64) throws -> Int64 { guard value != Int64.min else { throw BudgetError.overflow }; return value < 0 ? -value : value }
    public static func power(_ value: Decimal, _ exponent: Int) throws -> Decimal {
        guard exponent != Int.min else { throw BudgetError.overflow }
        if exponent < 0 { return try Money.divide(1, power(value, -exponent)) }
        var result = Decimal(1), base = value, n = exponent
        while n > 0 { if n & 1 == 1 { result = try Money.multiply(result, base) }; n >>= 1; if n > 0 { base = try Money.multiply(base, base) } }
        return result
    }
    public static func root(_ value: Decimal, degree: Int) throws -> Decimal {
        guard degree > 0, degree <= 10_000, value >= 0 else { throw BudgetError.invalid("Не поддержан период эффективной ставки.") }
        if value == 0 || value == 1 || degree == 1 { return value }
        var low = Decimal(0), high = max(1, value)
        let epsilon = Decimal(string: "0.0000000000000000000000001")!
        for _ in 0..<160 {
            let middle = (low + high) / 2
            if let raised = try? power(middle, degree), raised <= value { low = middle } else { high = middle }
            if high - low < epsilon { return (low + high) / 2 }
        }
        return (low + high) / 2
    }
    public static func monthlyRate(_ terms: FinancialTerms) throws -> Decimal? {
        guard let rate = try terms.rate() else { return nil }
        switch terms.rateKind { case .nominalAnnual: return try Money.divide(rate, 12); case .effectiveAnnual: return try root(1 + rate, degree: 12) - 1; case .periodic: return rate }
    }
    public static func levelPayment(principal: Int64, periodRates: [Decimal], rounding: FinanceRounding = .halfUp) throws -> Int64 {
        guard principal >= 0, !periodRates.isEmpty, periodRates.count <= 10000, periodRates.allSatisfy({ $0 >= 0 }) else { throw BudgetError.invalid("Проверьте ставки периодов платежа.") }
        var accumulated = Decimal(1), discounted = Decimal(0)
        for rate in periodRates { accumulated = try Money.multiply(accumulated, 1 + rate); discounted += try Money.divide(1, accumulated) }
        return try rounded(Money.divide(Decimal(principal), discounted), mode: rounding)
    }
    public static func annuity(principal: Int64, monthlyRate: Decimal, periods: Int, rounding: FinanceRounding = .halfUp) throws -> Int64 {
        guard principal >= 0, monthlyRate >= 0, periods > 0, periods <= 10_000 else { throw BudgetError.invalid("Проверьте долг, ставку и число платежей.") }
        if monthlyRate == 0 { return try rounded(Money.divide(Decimal(principal), Decimal(periods)), mode: rounding) }
        let denominator = 1 - (try power(1 + monthlyRate, -periods))
        return try rounded(Money.divide(Money.multiply(Decimal(principal), monthlyRate), denominator), mode: rounding)
    }
    public static func days(_ start: Day, _ end: Day) -> Int { Day.calendar.dateComponents([.day], from: start.date, to: end.date).day ?? 0 }
    public static func year(_ day: Day) -> Int { Int(day.rawValue.prefix(4))! }
    public static func month(_ day: Day) -> Int { Int(day.rawValue.dropFirst(5).prefix(2))! }
    public static func day(_ day: Day) -> Int { Int(day.rawValue.suffix(2))! }
    public static func leap(_ year: Int) -> Bool { year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) }
    public static func addingMonths(_ day: Day, _ count: Int, anchor: Int? = nil) throws -> Day {
        guard let date = Day.calendar.date(byAdding: .month, value: count, to: day.firstOfMonth.date) else { throw BudgetError.invalid("Дата вне поддерживаемого календаря.") }
        let y = Day.calendar.component(.year, from: date), m = Day.calendar.component(.month, from: date)
        let first = try Day(String(format: "%04d-%02d-01", y, m)); let target = min(anchor ?? self.day(day), self.day(first.lastOfMonth))
        guard target > 0 else { throw BudgetError.invalid("День платежа должен быть от 1 до 31.") }
        return try Day(String(format: "%04d-%02d-%02d", y, m, target))
    }
    public static func fraction(_ start: Day, _ end: Day, basis: InterestBasis) throws -> Decimal {
        guard end >= start else { throw BudgetError.invalid("Конец начисления раньше начала.") }
        if basis == .actual365 { return Decimal(days(start, end)) / 365 }
        if basis == .actual360 { return Decimal(days(start, end)) / 360 }
        if basis == .actualActual {
            var cursor = start, total = Decimal(0)
            while cursor < end {
                let y = year(cursor), next = y < 9999 ? try Day(String(format: "%04d-01-01", y + 1)) : end
                let boundary = min(end, next); total += Decimal(days(cursor, boundary)) / Decimal(leap(y) ? 366 : 365); cursor = boundary
            }
            return total
        }
        var d1 = day(start), d2 = day(end)
        if basis == .thirtyE360 { d1 = min(30, d1); d2 = min(30, d2) }
        else if basis == .thirtyUS360 {
            let firstFebruaryEnd = month(start) == 2 && start == start.lastOfMonth
            if firstFebruaryEnd || d1 == 31 { d1 = 30 }
            if (month(end) == 2 && end == end.lastOfMonth && firstFebruaryEnd) || (d2 == 31 && d1 >= 30) { d2 = 30 }
        }
        let count = (year(end) - year(start)) * 360 + (month(end) - month(start)) * 30 + d2 - d1
        return Decimal(count) / 360
    }
    public static func interest(principal: Int64, annualPercent: String, start: Day, end: Day, basis: InterestBasis = .actual365, rounding: FinanceRounding = .halfUp) throws -> Int64 {
        guard principal >= 0 else { throw BudgetError.invalid("База начисления не может быть отрицательной.") }
        let rate = try Money.decimal(annualPercent) / 100
        guard rate >= 0 else { throw BudgetError.invalid("Для отрицательной ставки используйте ручной график с отдельным расходом.") }
        return try rounded(Money.multiply(Money.multiply(Decimal(principal), rate), fraction(start, end, basis: basis)), mode: rounding)
    }
    public static func isBusinessDay(_ date: Day, calendar: BankCalendar) -> Bool {
        if calendar.workingExceptions.contains(date) { return true }
        let weekday = Day.calendar.component(.weekday, from: date.date)
        return weekday != 1 && weekday != 7 && !calendar.holidays.contains(date)
    }
    public static func shifted(_ date: Day, rule: BusinessDayRule, calendar: BankCalendar?) throws -> (Day, Bool) {
        guard rule != .none else { return (date, true) }
        guard let calendar, calendar.years.contains(year(date)) else { return (date, false) }
        func find(_ direction: Int) throws -> (Day, Bool) {
            var cursor = date
            for _ in 0..<370 {
                guard calendar.years.contains(year(cursor)) else { return (date, false) }
                if isBusinessDay(cursor, calendar: calendar) { return (cursor, true) }; cursor = cursor.adding(direction)
            }
            throw BudgetError.invalid("В банковском календаре не найден рабочий день.")
        }
        if rule == .preceding { return try find(-1) }
        let next = try find(1)
        if rule == .modifiedFollowing && next.0.month != date.month { return try find(-1) }
        return next
    }
    public static func paymentDates(_ contract: FinancialContract, through horizon: Day) throws -> [Day] {
        let end = min(contract.end ?? horizon, horizon)
        guard end > contract.start else { return [] }
        if contract.frequency == .manual { return contract.manualRows.map(\.date).filter { $0 <= end }.sorted() }
        if contract.frequency == .maturity { return [end] }
        let anchor = contract.paymentDay ?? day(contract.firstPayment ?? contract.start)
        guard (1...31).contains(anchor), contract.everyNDays > 0 else { throw BudgetError.invalid("Проверьте день и периодичность платежа.") }
        var cursor: Day
        if let first = contract.firstPayment { cursor = first }
        else {
            switch contract.frequency {
            case .monthly: cursor = try addingMonths(contract.start, 1, anchor: anchor)
            case .quarterly: cursor = try addingMonths(contract.start, 3, anchor: anchor)
            case .yearly: cursor = try addingMonths(contract.start, 12, anchor: anchor)
            case .weekly: cursor = contract.start.adding(7)
            case .fortnightly: cursor = contract.start.adding(14)
            case .everyNDays: cursor = contract.start.adding(contract.everyNDays)
            case .twiceMonthly: cursor = contract.start.adding(1)
            default: cursor = end
            }
        }
        var dates: [Day] = []
        if contract.frequency == .twiceMonthly {
            guard (1...31).contains(contract.secondPaymentDay), contract.secondPaymentDay != anchor else { throw BudgetError.invalid("Две даты месяца должны различаться.") }
            var month = contract.start.firstOfMonth
            while month <= end.firstOfMonth {
                for d in [anchor, contract.secondPaymentDay].sorted() {
                    let value = try addingMonths(month, 0, anchor: d)
                    if value >= cursor && value > contract.start && value <= end && !dates.contains(value) { dates.append(value) }
                }
                month = try addingMonths(month, 1, anchor: 1)
                guard dates.count <= 10_000 else { throw BudgetError.invalid("Слишком длинный график; сократите горизонт.") }
            }
        } else {
            guard cursor > contract.start else { throw BudgetError.invalid("Первый платёж должен быть после начала договора.") }
            while cursor <= end {
                dates.append(cursor)
                guard dates.count <= 10_000 else { throw BudgetError.invalid("Слишком длинный график; сократите горизонт.") }
                switch contract.frequency {
                case .monthly: cursor = try addingMonths(cursor, 1, anchor: anchor)
                case .quarterly: cursor = try addingMonths(cursor, 3, anchor: anchor)
                case .yearly: cursor = try addingMonths(cursor, 12, anchor: anchor)
                case .weekly: cursor = cursor.adding(7)
                case .fortnightly: cursor = cursor.adding(14)
                default: cursor = cursor.adding(contract.everyNDays)
                }
            }
        }
        if contract.end != nil && dates.last != end { dates.append(end) }
        return dates
    }
}
