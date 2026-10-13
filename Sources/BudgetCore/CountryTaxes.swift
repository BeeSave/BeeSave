import Foundation

public enum TaxRefundStage: String, Codable, CaseIterable, Sendable {
    case estimate, prepared, submitted, approved, received
    public var title: String { switch self { case .estimate: "Оценка"; case .prepared: "Подготовлено"; case .submitted: "Подано"; case .approved: "Подтверждено"; case .received: "Получено" } }
}
public struct ChildEducationCost: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var eligibleCost: Int64; public var claimedByOtherParent: Int64
    public init(eligibleCost: Int64, claimedByOtherParent: Int64 = 0) { self.eligibleCost = eligibleCost; self.claimedByOtherParent = claimedByOtherParent }
}
public struct TaxProfile: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID(); public var title = "НДФЛ"; public var country = "RU"; public var year = 2026; public var resident = true
    public var ownerID: UUID?; public var grossEmployment: Int64 = 0; public var incomeIsNet = false; public var withheld: Int64 = 0; public var verifiedOtherDeductions: Int64 = 0
    public var housingEligible = false; public var housingAfter2014 = true; public var housingCost: Int64 = 0; public var housingUsed: Int64 = 0
    public var interestEligible = false; public var interestCost: Int64 = 0; public var interestUsed: Int64 = 0
    public var socialEligible = false; public var treatment: Int64 = 0; public var education: Int64 = 0; public var otherSocial: Int64 = 0; public var socialUsed: Int64 = 0
    public var expensiveTreatment: Int64 = 0; public var childEducation: [ChildEducationCost] = []
    public var unsupportedIncome = false; public var stage = TaxRefundStage.estimate; public var expectedOn: Day?; public var refundOperationID: UUID?; public var reducedWithholding: Int64 = 0
    public init() {}
}
public struct CountryRuleManifest: Codable, Equatable, Sendable {
    public var country: String; public var year: Int; public var version: String; public var checkedOn: Day
    public var sources: [String]; public var coverage: [String]; public var exclusions: [String]
}
public struct TaxCalculation: Codable, Equatable, Identifiable, Sendable {
    public var input: TaxProfile?
    public var id = UUID(); public var profileID: UUID; public var snapshotRevision: UInt64; public var date = Date(); public var rules: CountryRuleManifest?
    public var base: Int64?; public var taxBefore: Int64?; public var tax: Int64?; public var payable: Int64?; public var refund: Int64?
    public var socialBase: Int64 = 0; public var housingBase: Int64 = 0; public var interestBase: Int64 = 0
    public var assumptions: [String] = []; public var missing: [String] = []
    public var complete: Bool { missing.isEmpty && tax != nil }
}
public protocol CountryTaxModule: Sendable {
    var country: String { get }
    func calculate(_ profile: TaxProfile, revision: UInt64) throws -> TaxCalculation
}
public enum CountryModules {
    public static func taxes(country: String) -> (any CountryTaxModule)? { country == "RU" ? RussiaPersonalTaxModule() : nil }
    public static func calculate(_ profile: TaxProfile, revision: UInt64) throws -> TaxCalculation {
        guard let module = taxes(country: profile.country) else { return TaxCalculation(profileID: profile.id, snapshotRevision: revision, missing: ["Нет модуля выбранной страны"]) }
        return try module.calculate(profile, revision: revision)
    }
}
public struct RussiaPersonalTaxModule: CountryTaxModule {
    public let country = "RU"
    public init() {}
    public static func manifest(year: Int) -> CountryRuleManifest? {
        guard [2025, 2026].contains(year) else { return nil }
        return CountryRuleManifest(country: "RU", year: year, version: "ru.personal.\(year).1", checkedOn: try! Day("2026-10-13"), sources: [
            "https://www.nalog.gov.ru/rn39/taxation/taxes/ndfl/",
            "https://www.nalog.gov.ru/rn77/taxation/taxes/ndfl/nalog_vichet/im_nv/im_nv_pi/",
            "https://www.nalog.gov.ru/rn77/taxation/taxes/ndfl/nalog_vichet/soc_nv/soc_nv_pm/",
            "https://www.nalog.gov.ru/rn77/taxation/taxes/ndfl/nalog_vichet/soc_nv/soc_nv_ob/"
        ], coverage: ["Трудовые доходы резидента", "Жильё/целевые проценты после 2014", "Лечение/обучение с подтверждёнными условиями"], exclusions: ["Доходы других налоговых баз", "УСН/НПД/налог на прибыль", "Особые ставки и старые права до 2014", "Подача декларации"])
    }
    /// Amounts are minor RUB units. The annual tax is rounded to whole rubles once.
    public static func employmentTax(base: Int64) throws -> Int64 {
        guard base >= 0 else { throw BudgetError.invalid("Налоговая база не может быть отрицательной.") }
        let ceilings: [Int64] = [240_000_000, 500_000_000, 2_000_000_000, 5_000_000_000, Int64.max]
        let rates = [13, 15, 18, 20, 22]; var previous: Int64 = 0, minor = Decimal(0)
        for (index, ceiling) in ceilings.enumerated() {
            let piece = max(0, min(base, ceiling) - previous)
            minor += try Money.divide(Money.multiply(Decimal(piece), Decimal(rates[index])), 100)
            previous = ceiling; if base <= ceiling { break }
        }
        let rubles = try FinanceMath.rounded(Money.divide(minor, 100))
        return try Money.integer(Money.multiply(Decimal(rubles), 100))
    }
    public func calculate(_ p: TaxProfile, revision: UInt64) throws -> TaxCalculation {
        var r = TaxCalculation(profileID: p.id, snapshotRevision: revision); r.input = p; r.rules = Self.manifest(year: p.year)
        if r.rules == nil { r.missing.append("Год не поддержан: доступны 2025 и 2026") }
        if !p.resident { r.missing.append("Модуль рассчитан на налогового резидента РФ") }
        if p.incomeIsNet { r.missing.append("Для расчёта нужна сумма до удержания НДФЛ; чистый доход не облагается второй раз") }
        if p.unsupportedIncome { r.missing.append("Есть доходы вне покрытия трудовой налоговой базы") }
        if !p.housingAfter2014 && (p.housingCost > 0 || p.interestCost > 0) { r.missing.append("Права/договоры до 2014 требуют отдельного расчёта") }
        let inputs = [p.grossEmployment,p.withheld,p.verifiedOtherDeductions,p.housingCost,p.housingUsed,p.interestCost,p.interestUsed,p.treatment,p.education,p.otherSocial,p.socialUsed,p.expensiveTreatment,p.reducedWithholding] + p.childEducation.flatMap { [$0.eligibleCost,$0.claimedByOtherParent] }
        guard inputs.allSatisfy({ $0 >= 0 }), p.housingUsed <= 200_000_000, p.interestUsed <= 300_000_000, p.socialUsed <= 15_000_000, p.childEducation.allSatisfy({ $0.claimedByOtherParent <= 11_000_000 }) else { throw BudgetError.invalid("Проверьте неотрицательные суммы и уже использованные лимиты вычетов.") }
        if !p.housingEligible && p.housingCost > 0 { r.missing.append("Не подтверждены условия жилищного вычета") }
        if !p.interestEligible && p.interestCost > 0 { r.missing.append("Не подтверждены условия вычета по целевым процентам") }
        if !p.socialEligible && (p.treatment > 0 || p.education > 0 || p.expensiveTreatment > 0 || p.otherSocial > 0 || !p.childEducation.isEmpty) { r.missing.append("Не подтверждены условия социальных вычетов") }
        guard r.missing.isEmpty else { return r }
        let originalBase = max(0, p.grossEmployment - p.verifiedOtherDeductions)
        r.taxBefore = try Self.employmentTax(base: originalBase)
        let common = try Money.add(try Money.add(p.treatment,p.education), p.otherSocial)
        let children = try p.childEducation.reduce(Int64(0)) { try Money.add($0, min($1.eligibleCost, 11_000_000 - $1.claimedByOtherParent)) }
        let eligibleSocial = p.socialEligible ? try Money.add(try Money.add(min(common,15_000_000 - p.socialUsed), p.expensiveTreatment), children) : 0
        r.socialBase = min(originalBase, eligibleSocial)
        var available = originalBase - r.socialBase
        r.housingBase = p.housingEligible ? min(available, min(p.housingCost,200_000_000 - p.housingUsed)) : 0; available -= r.housingBase
        r.interestBase = p.interestEligible ? min(available, min(p.interestCost,300_000_000 - p.interestUsed)) : 0; available -= r.interestBase
        r.base = available; r.tax = try Self.employmentTax(base: available)
        let settled = try Money.add(p.withheld, -p.reducedWithholding)
        guard settled >= 0 else { throw BudgetError.invalid("Уменьшение удержаний превышает указанный налог.") }
        r.payable = max(0, r.tax! - settled); r.refund = max(0, settled - r.tax!)
        r.assumptions = ["Введён совокупный трудовой доход за год", "Условия/документы проверены пользователем", "Социальный вычет используется до переносимых имущественных вычетов", "Возмещение — оценка; дата поступления не гарантирована"]
        return r
    }
}
