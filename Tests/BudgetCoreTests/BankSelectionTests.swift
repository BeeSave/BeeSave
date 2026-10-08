import XCTest
@testable import BudgetCore

final class BankSelectionTests: XCTestCase {
    private func catalog() -> BankCatalog {
        func bank(_ id: String, _ name: String, _ country: String, _ rank: Int?) -> BankRecord {
            var bank = BankRecord(id: id, name: name, country: country)
            bank.assetRank = rank
            return bank
        }
        var inactive = bank("closed", "Closed", "CA", 1); inactive.active = false
        var alias = bank("canada-second", "Z Canadian", "CA", 2); alias.aliases = ["Maple"]
        return BankCatalog(manifest: BankCatalog.shared.manifest, banks: [
            bank("usa", "US Bank", "US", 1), bank("canada-first", "Z Largest", "CA", 1),
            alias, bank("canada-extra", "A Additional", "CA", nil),
            bank("mali", "Mali Bank", "ML", 1), bank("niger", "Niger Bank", "NE", 1),
            bank("chad", "Chad Bank", "TD", 1), inactive
        ])
    }

    func testEconomicScopeRetainsPriorMarketsAndPreparedLogoRequirements() {
        XCTAssertEqual(BankMarket.all.count, 40)
        XCTAssertEqual(Set(BankMarket.all.map(\.id)).count, 40)
        XCTAssertEqual(BankMarket.all.compactMap(\.areaRank).sorted(), Array(1...30))
        XCTAssertEqual(BankMarket.all.compactMap(\.economyRank).sorted(), Array(1...20))
        XCTAssertEqual(BankMarket.all.filter { $0.economyRank != nil }.sorted { $0.economyRank! < $1.economyRank! }.map(\.id),
                       ["US", "CN", "DE", "JP", "GB", "IN", "FR", "RU", "IT", "CA", "BR", "ES", "KR", "AU", "MX", "TR", "ID", "NL", "SA", "CH"])
        XCTAssertEqual(BankMarket.all.filter(\.requiresLogos).count, 10)
        XCTAssertEqual(BankMarket.all.filter { $0.requiresLogos && !["RU", "US", "GB"].contains($0.id) }.count, 7)
        XCTAssertTrue(BankMarket.get("PE")?.requiresLogos == false)
        XCTAssertNotNil(BankMarket.get("PE"))
        XCTAssertTrue(BankMarket.get("JP")?.requiresLogos == false)
        XCTAssertTrue(BankMarket.get("TD")?.requiresLogos == false)
        for market in BankMarket.all { XCTAssertNoThrow(try Currency.get(market.currency)) }
    }

    func testEveryNationalCurrencyPrioritizesItsCountryAndSharedCurrenciesKeepAllCountries() {
        for market in BankMarket.all {
            XCTAssertTrue(BankMarket.preferredCountries(currency: market.currency).contains(market.id))
        }
        XCTAssertEqual(BankMarket.preferredCountries(currency: "XOF"), ["ML", "NE"])
        XCTAssertEqual(BankMarket.preferredCountries(currency: "XAF"), ["TD"])
        XCTAssertEqual(BankMarket.preferredCountries(currency: "EUR"), ["DE", "ES", "IT", "NL", "FR"])
        for (currency, country) in [("JPY", "JP"), ("KRW", "KR"), ("TRY", "TR"), ("CHF", "CH")] {
            XCTAssertEqual(BankMarket.preferredCountries(currency: currency), [country])
        }
        XCTAssertTrue(BankMarket.preferredCountries(currency: "NZD").isEmpty)
    }

    func testEuroGroupsAreAllPrioritizedInRussianOrderAndEmptyMarketsStayHidden() {
        var data = catalog()
        for country in ["FR", "NL", "IT", "DE", "ES"] {
            var small = BankRecord(id: country + "-small", name: "A Smaller Bank", country: country); small.assetRank = 2
            var large = BankRecord(id: country + "-large", name: "Z Larger Bank", country: country); large.assetRank = 1
            data.banks += [small, large]
        }
        let groups = data.selectionGroups("", primaryCurrency: "EUR")
        XCTAssertEqual(groups.prefix(5).map(\.id), ["DE", "ES", "IT", "NL", "FR"])
        for group in groups.prefix(5) { XCTAssertEqual(group.banks.map(\.assetRank), [1, 2]) }
        XCTAssertFalse(groups.contains { $0.id == "JP" })
        XCTAssertEqual(data.selectionGroups("Larger", primaryCurrency: "USD").flatMap(\.banks).count, 5)
        XCTAssertEqual(data.selectionGroups("Canadian", primaryCurrency: "EUR").first?.id, "CA")
        XCTAssertEqual(data.search("", primaryCurrency: "EUR").prefix(10).map(\.country), ["DE", "DE", "ES", "ES", "IT", "IT", "NL", "NL", "FR", "FR"])
    }

    func testRanksComeBeforeAlphabeticalExtrasAndPrimaryCurrencyChangesCountryOnly() {
        let data = catalog()
        XCTAssertEqual(data.search("", primaryCurrency: "CAD").prefix(3).map(\.id), ["canada-first", "canada-second", "canada-extra"])
        XCTAssertEqual(data.search("", primaryCurrency: "USD").first?.id, "usa")
        XCTAssertEqual(data.search("Maple", primaryCurrency: "USD").map(\.id), ["canada-second"])
        XCTAssertFalse(data.search("").contains { $0.id == "closed" })
        XCTAssertTrue(data.search("", includeInactive: true).contains { $0.id == "closed" })
    }

    func testGroupsMergeManualBanksAfterRankedBanksAndPutUnknownCountryLast() {
        var local = UserBank(name: "A My Bank", country: .us); local.id = "custom"
        var unknown = UserBank(name: "Unknown"); unknown.id = "unknown"
        var archived = UserBank(name: "Archived", country: .us); archived.archived = true
        let groups = catalog().selectionGroups("", primaryCurrency: "USD", userBanks: [local, unknown, archived])
        XCTAssertEqual(groups.first?.id, "US")
        XCTAssertEqual(groups.first?.banks.map(\.id), ["usa", "custom"])
        XCTAssertEqual(groups.last?.id, "OTHER")
        XCTAssertEqual(groups.last?.banks.map(\.id), ["unknown"])
        XCTAssertEqual(catalog().selectionGroups("", primaryCurrency: "XOF").prefix(2).map(\.id), ["ML", "NE"])
        XCTAssertEqual(catalog().selectionGroups("", primaryCurrency: "XAF").first?.id, "TD")
    }

    func testAllResultsAreAccessibleAndMissingRankDecodesLegacyRecords() throws {
        let data = catalog()
        let legacy = try JSONDecoder().decode(BankRecord.self, from: JSONEncoder().encode(BankRecord(id: "legacy", name: "Legacy", country: "CA")))
        XCTAssertNil(legacy.assetRank)
        var extended = data
        extended.banks += (1...90).map { BankRecord(id: "extra-\($0)", name: "Extra \($0)", country: "CA") }
        let choices = extended.selectionGroups("Extra", primaryCurrency: "USD").flatMap(\.banks)
        XCTAssertEqual(choices.count, 90)
        XCTAssertTrue(choices.contains { $0.id == "extra-90" })
        XCTAssertTrue(data.selectionGroups("no match", primaryCurrency: "CAD").isEmpty)
    }

    func testBundledSelectionRemainsResponsiveWithAllRegistryRecords() throws {
        guard ProcessInfo.processInfo.environment["BEESAVE_BANK_PERF"] == "1" else { throw XCTSkip("Run catalogue responsiveness in an optimized build.") }
        let began = Date()
        let data = BankCatalog.shared
        let initial = data.selectionGroups("", primaryCurrency: "CAD")
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(began), 2)
        XCTAssertGreaterThan(data.banks.count, 10_000)
        XCTAssertEqual(initial.first?.id, "CA")
        XCTAssertEqual(initial.flatMap(\.banks).count, data.banks.filter(\.active).count)
        for currency in ["CAD", "USD", "GBP", "XOF", "SAR", "EUR"] {
            for query in ["", "bank", "Scotia", "Unmatched fictional query"] {
                let started = Date()
                _ = data.selectionGroups(query, primaryCurrency: currency)
                let elapsed = Date().timeIntervalSince(started)
                XCTAssertLessThanOrEqual(elapsed, 2, currency + " / " + query)
                print("BANK_PICKER_PERF currency=\(currency) query=\(query) seconds=\(elapsed)")
            }
        }
    }
}
