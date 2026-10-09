#if DEBUG && UI_SMOKE
import Foundation
import BudgetCore

extension AppModel {
    func prepareHome017QA() {
        loadPreview(.filled)
        perform { db in
            db.settings.reportCurrency = "GBP"
            db.rates.append(FXRate(base: "GBP", quote: "RUB", rate: "120", date: .today))
        }
    }

    func prepareDashboardCurrencyQA(overflow: Bool) {
        guard root.lastPathComponent.hasPrefix("BeeSaveSmoke-") else { return }
        loadPreview(.empty)
        perform { db in
            db.settings.dashboardCurrencies = ["USD", "GBP", "JPY", "KWD", "EUR"]
            for (name, code, amount) in [
                ("Очень длинное название вымышленного долларового счёта для проверки переноса", "USD", Int64(-123_456_789_012)),
                ("Йены · вымышленный счёт", "JPY", 999_999_999),
                ("Динары · вымышленный счёт", "KWD", 1),
                ("Нулевой рублёвый счёт", "RUB", 0)
            ] { try Ledger.saveAccount(Account(name: name, currency: code), opening: amount, in: &db) }
            db.rates = [FXRate(base: "USD", quote: "RUB", rate: overflow ? "100000000000" : "92", date: .today.adding(-8)), FXRate(base: "JPY", quote: "RUB", rate: "0.000000123456789", date: .today)]
        }
        section = .dashboard
    }
}
#endif
