import Foundation

public enum BudgetError: LocalizedError, Equatable {
    case invalid(String), missing(String), conflict(String), overflow, locked, corrupt, newerVersion, wrongKey, busy, storage(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .missing(let s), .conflict(let s), .storage(let s): return s
        case .overflow: return "Сумма слишком велика. Уменьшите значение."
        case .locked: return "База закрыта. Выполните вход."
        case .corrupt: return "Файл повреждён. Выберите проверенную резервную копию; исходный файл сохранён."
        case .newerVersion: return "Версия файла новее поддерживаемой. Откройте его совместимой версией приложения."
        case .wrongKey: return "Неверный пароль или ключ восстановления. Проверьте ввод."
        case .busy: return "База открыта другим экземпляром. Закройте его и повторите."
        }
    }
}

public struct Day: Codable, Hashable, Comparable, CustomStringConvertible, Sendable {
    public let rawValue: String
    public init(_ value: String) throws {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { throw BudgetError.invalid("Дата должна быть существующим днём YYYY-MM-DD.") }
        let p = value.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]), y >= 1,
              let date = Self.calendar.date(from: DateComponents(year: y, month: m, day: d)),
              Self.calendar.component(.year, from: date) == y,
              Self.calendar.component(.month, from: date) == m,
              Self.calendar.component(.day, from: date) == d else {
            throw BudgetError.invalid("Дата должна быть существующим днём YYYY-MM-DD.")
        }
        rawValue = value
    }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public static func < (l: Day, r: Day) -> Bool { l.rawValue < r.rawValue }
    public var description: String { rawValue }
    public var month: String { String(rawValue.prefix(7)) }
    public static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    public static func local(_ date: Date) -> Day {
        let c = Calendar(identifier: .gregorian); let p = c.dateComponents([.year, .month, .day], from: date)
        return try! Day(String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!))
    }
    public static var today: Day { local(Date()) }
    public var date: Date { Self.calendar.date(from: DateComponents(year: Int(rawValue.prefix(4)), month: Int(rawValue.dropFirst(5).prefix(2)), day: Int(rawValue.suffix(2))))! }
    public func adding(_ days: Int) -> Day { Self.utc(Self.calendar.date(byAdding: .day, value: days, to: date)!) }
    public static func utc(_ date: Date) -> Day { let p = calendar.dateComponents([.year, .month, .day], from: date); return try! Day(String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)) }
    public var firstOfMonth: Day { try! Day(month + "-01") }
    public var lastOfMonth: Day { Self.utc(Self.calendar.date(byAdding: DateComponents(month: 1, day: -1), to: firstOfMonth.date)!) }
}

public struct Currency: Codable, Hashable, Identifiable, Sendable {
    public var id: String { code }
    public let code: String
    public let scale: Int
    public var name: String { Locale(identifier: "ru_RU").localizedString(forCurrencyCode: code) ?? code }
    public var label: String { "\(code) — \(name)" }
    public static let catalog: [Currency] = {
        let codes = "RUB USD GBP AED AFN ALL AMD AOA ARS AUD AWG AZN BAM BBD BDT BHD BIF BMD BND BOB BRL BSD BTN BWP BYN BZD CAD CDF CHF CLP CNY COP CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RWF SAR SBD SCR SDG SEK SGD SHP SLE SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX UYU UZS VED VES VND VUV WST XAF XCD XCG XOF XPF YER ZAR ZMW ZWG"
        let zero = Set("BIF CLP DJF GNF ISK JPY KMF KRW PYG RWF UGX VND VUV XAF XOF XPF".split(separator: " ").map(String.init))
        let three = Set("BHD IQD JOD KWD LYD OMR TND".split(separator: " ").map(String.init))
        return codes.split(separator: " ").map { let s = String($0); return Currency(code: s, scale: zero.contains(s) ? 0 : three.contains(s) ? 3 : 2) }
    }()
    public static func get(_ code: String) throws -> Currency { guard let c = catalog.first(where: { $0.code == code }) else { throw BudgetError.invalid("Неизвестная валюта \(code).") }; return c }
}

public enum Money {
    public static func decimal(_ text: String) throws -> Decimal {
        guard text.range(of: "^[+-]?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let d = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !d.isNaN else { throw BudgetError.invalid("Введите число без разделителей тысяч.") }
        return d
    }
    public static func power(_ scale: Int) -> Decimal { (0..<scale).reduce(Decimal(1)) { v, _ in v * 10 } }
    public static func multiply(_ a: Decimal, _ b: Decimal) throws -> Decimal {
        var x = a, y = b, z = Decimal(); let e = NSDecimalMultiply(&z, &x, &y, .plain)
        guard e == .noError || e == .lossOfPrecision else { throw BudgetError.overflow }; return z
    }
    public static func divide(_ a: Decimal, _ b: Decimal) throws -> Decimal {
        guard b != 0 else { throw BudgetError.invalid("Курс не может быть нулевым.") }
        var x = a, y = b, z = Decimal(); let e = NSDecimalDivide(&z, &x, &y, .plain)
        guard e == .noError || e == .lossOfPrecision else { throw BudgetError.overflow }; return z
    }
    public static func integer(_ value: Decimal, round: Bool = false) throws -> Int64 {
        var d = value, rounded = Decimal(); NSDecimalRound(&rounded, &d, 0, .plain)
        guard !rounded.isNaN, rounded <= Decimal(Int64.max), rounded >= Decimal(Int64.min), round || rounded == value else { throw BudgetError.invalid("Недопустимая точность суммы или переполнение.") }
        return NSDecimalNumber(decimal: rounded).int64Value
    }
    public static func parse(_ text: String, currency: String) throws -> Int64 {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let scale = try Currency.get(currency).scale
        if let fraction = s.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first {
            guard fraction.dropFirst(scale).allSatisfy({ $0 == "0" }) else { throw BudgetError.invalid("Сумма содержит доли меньше минимальной единицы \(currency).") }
        }
        return try integer(multiply(decimal(s), power(scale)))
    }
    public static func string(_ minor: Int64, currency: String) -> String {
        let scale = (try? Currency.get(currency).scale) ?? 2
        let negative = minor < 0; let digits = String(minor.magnitude)
        guard scale > 0 else { return (negative ? "-" : "") + digits }
        let p = String(repeating: "0", count: max(0, scale + 1 - digits.count)) + digits
        return (negative ? "-" : "") + p.dropLast(scale) + "." + p.suffix(scale)
    }
    public static func display(_ minor: Int64, currency: String) -> String { string(minor, currency: currency) + " " + currency }
    public static func add(_ a: Int64, _ b: Int64) throws -> Int64 { let (v, overflow) = a.addingReportingOverflow(b); guard !overflow else { throw BudgetError.overflow }; return v }
    public static func convert(_ minor: Int64, from: String, to: String, rate: String) throws -> Int64 {
        if from == to { _ = try Currency.get(from); guard try decimal(rate) == 1 else { throw BudgetError.invalid("Для одинаковых валют курс равен 1.") }; return minor }
        let r = try decimal(rate); guard r > 0 else { throw BudgetError.invalid("Курс должен быть положительным.") }
        let base = try divide(Decimal(minor), power(Currency.get(from).scale))
        let result = try multiply(multiply(base, r), power(Currency.get(to).scale))
        return try integer(result, round: true)
    }
    public static func ratio(from amount: Int64, currency: String, to received: Int64, toCurrency: String) throws -> String {
        guard amount > 0, received > 0 else { throw BudgetError.invalid("Обе суммы перевода должны быть положительными.") }
        return NSDecimalNumber(decimal: try divide(divide(Decimal(received), power(Currency.get(toCurrency).scale)), divide(Decimal(amount), power(Currency.get(currency).scale)))).stringValue
    }
}
