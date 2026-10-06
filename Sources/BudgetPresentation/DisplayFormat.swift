import Foundation
import BudgetCore

public enum DisplayFormat {
    public static func money(_ minor: Int64, currency: String) -> String {
        let scale = (try? Currency.get(currency).scale) ?? 2
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = scale; formatter.maximumFractionDigits = scale
        let value = NSDecimalNumber(decimal: Decimal(minor) / Money.power(scale))
        return (formatter.string(from: value) ?? Money.string(minor, currency: currency)) + " " + currency
    }
    public static func rate(_ text: String) -> String {
        guard let decimal = try? Money.decimal(text) else { return text }
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true; formatter.minimumSignificantDigits = 1; formatter.maximumSignificantDigits = 8
        return formatter.string(from: NSDecimalNumber(decimal: decimal)) ?? text
    }
    public static func valuation(_ value: Valuation, currency: String) -> String {
        money(value.known, currency: currency) + (value.partial ? " · частично (\(value.partialDescription))" : "")
    }
}
