import XCTest
@testable import BudgetCore

final class DashboardCurrencyTests: XCTestCase {
    func fixture() throws -> Database {
        var db = Database()
        for (name, code, amount) in [("Основной", "RUB", Int64(3_292_000)), ("Наличные", "RUB", 185_000), ("Доллары", "USD", 20_000)] {
            try Ledger.saveAccount(Account(name: name, currency: code), opening: amount, in: &db)
        }
        db.rates = [FXRate(base: "USD", quote: "RUB", rate: "92", date: .today)]
        return db
    }
    func testNativeBalancesAndFullTotalInBaseCurrency() throws {
        var db = try fixture(); db.settings.reportCurrency = "GBP"
        let rows = try Reports.accountBalances(db, filters: Filters(), currency: db.settings.baseCurrency)
        XCTAssertEqual(rows.map(\.amount), [3_292_000, 185_000, 20_000])
        XCTAssertEqual(rows.last?.account.currency, "USD"); XCTAssertEqual(rows.last?.value.known, 1_840_000)
        XCTAssertEqual(try Reports.total(rows.map(\.reportRow)).known, 5_317_000)
        XCTAssertEqual(rows.map(\.reportRow), try Reports.balances(db, filters: Filters(), currency: "RUB"))
        db.settings.baseCurrency = "USD"
        let usd = try Reports.accountBalances(db, filters: Filters(), currency: db.settings.baseCurrency)
        XCTAssertEqual(usd.map(\.amount), rows.map(\.amount)); XCTAssertEqual(usd.last?.value.known, 20_000)
        XCTAssertEqual(usd.last?.rate?.value, "1"); XCTAssertNil(usd.last?.rate?.date)
        // Total is the sum of individually rounded account valuations.
        XCTAssertEqual(try Reports.total(usd.map(\.reportRow)).known, 57_794)
    }
    func testMissingRatesKeepOriginalAndMarkTotalPartial() throws {
        var db = try fixture(); db.rates = []
        var rows = try Reports.accountBalances(db, filters: Filters(), currency: "RUB")
        XCTAssertEqual(rows.last?.amount, 20_000); XCTAssertNil(rows.last?.rate)
        let total = try Reports.total(rows.map(\.reportRow))
        XCTAssertTrue(total.partial); XCTAssertEqual(total.known, 3_477_000); XCTAssertEqual(total.currencies, ["USD"])
        db.rates = [FXRate(base: "USD", quote: "RUB", rate: "92", date: .today)]
        rows = try Reports.accountBalances(db, filters: Filters(), currency: "RUB")
        XCTAssertFalse(try Reports.total(rows.map(\.reportRow)).partial)
    }
    func testFiltersArchiveFutureAndMisleadingName() throws {
        var db = try fixture()
        var euro = Account(name: "Название USD, валюта EUR", currency: "EUR")
        try Ledger.saveAccount(euro, opening: -100, in: &db)
        euro.archived = true; try Ledger.saveAccount(euro, in: &db)
        var filters = Filters(start: .today.adding(-60), end: .today.adding(-30))
        filters.categories = [db.categories[0].id]; filters.projectID = UUID()
        var rows = try Reports.accountBalances(db, filters: filters, currency: "RUB")
        XCTAssertEqual(rows.count, 4); XCTAssertEqual(rows.last?.amount, -100); XCTAssertEqual(rows.last?.account.currency, "EUR")
        XCTAssertEqual(try Reports.total(rows.map(\.reportRow)).known, 5_317_000)
        filters.includeArchived = false; rows = try Reports.accountBalances(db, filters: filters, currency: "RUB")
        XCTAssertEqual(rows.count, 3)
        filters.accounts = [db.accounts[2].id]; filters.currency = "USD"
        XCTAssertEqual(try Reports.accountBalances(db, filters: filters, currency: "RUB").map(\.amount), [20_000])
        filters.currency = "GBP"; XCTAssertTrue(try Reports.accountBalances(db, filters: filters, currency: "RUB").isEmpty)
        db.accounts.append(Account(name: "Будущий", currency: "RUB", openedOn: .today.adding(1)))
        XCTAssertEqual(try Reports.accountBalances(db, filters: Filters(), currency: "RUB").count, 4)
    }
    func testTransferAdjustmentEditAndDeleteUpdateBothAmounts() throws {
        var db = try fixture(); let rub = db.accounts[0], usd = db.accounts[2]
        var transfer = Operation(kind: .transfer, accountID: rub.id, amount: 9_200)
        transfer.toAccountID = usd.id; transfer.toAmount = 100; transfer.transferRate = "0.01086956521739130434782608695652"
        try Ledger.saveOperation(transfer, in: &db)
        var rows = try Reports.accountBalances(db, filters: Filters(), currency: "RUB")
        XCTAssertEqual(rows.last?.amount, 20_100); XCTAssertEqual(rows.last?.value.known, 1_849_200)
        transfer.amount = 18_400; transfer.toAmount = 200; try Ledger.saveOperation(transfer, in: &db)
        rows = try Reports.accountBalances(db, filters: Filters(), currency: "RUB")
        XCTAssertEqual(rows.last?.amount, 20_200)
        db.operations.removeAll { $0.id == transfer.id }
        let adjustment = try Ledger.reconcile(accountID: usd.id, observed: -50, reason: "Вымышленная сверка", in: &db)
        XCTAssertNotNil(adjustment)
        rows = try Reports.accountBalances(db, filters: Filters(), currency: "RUB")
        XCTAssertEqual(rows.last?.amount, -50); XCTAssertEqual(rows.last?.value.known, -4_600)
        let before = db.operations; db.rates[0].rate = "93"
        XCTAssertEqual(try Reports.accountBalances(db, filters: Filters(), currency: "RUB").last?.value.known, -4_650)
        XCTAssertEqual(db.operations, before)
    }
    func testPrecisionZeroAndOverflow() throws {
        var db = Database()
        try Ledger.saveAccount(Account(name: "JPY", currency: "JPY"), opening: 3, in: &db)
        try Ledger.saveAccount(Account(name: "KWD", currency: "KWD"), opening: 1, in: &db)
        try Ledger.saveAccount(Account(name: "Ноль", currency: "RUB"), in: &db)
        db.rates = [FXRate(base: "JPY", quote: "RUB", rate: "0.555", date: .today), FXRate(base: "KWD", quote: "RUB", rate: "300", date: .today)]
        let rows = try Reports.accountBalances(db, filters: Filters(), currency: "RUB")
        XCTAssertEqual(rows.map(\.value.known), [167, 30, 0])
        db.operations[0].amount = Int64.max; db.rates[0].rate = "100000"
        XCTAssertThrowsError(try Reports.accountBalances(db, filters: Filters(), currency: "RUB"))
    }
    func testResolvedRateMetadataDirectInverseCrossStaleAndFuture() throws {
        let old = Day.today.adding(-8)
        let rates = [FXRate(base: "USD", quote: "RUB", rate: "92", date: old, provider: "Вымышленный источник"), FXRate(base: "GBP", quote: "RUB", rate: "115", date: old, provider: "Вымышленный источник"), FXRate(base: "USD", quote: "RUB", rate: "200", date: .today.adding(1))]
        let direct = try XCTUnwrap(Reports.resolvedRate(from: "USD", to: "RUB", rates: rates, on: .today))
        XCTAssertEqual(direct.value, "92"); XCTAssertEqual(direct.date, old); XCTAssertTrue(direct.stale())
        let inverse = try XCTUnwrap(Reports.resolvedRate(from: "RUB", to: "USD", rates: rates, on: .today))
        XCTAssertEqual(inverse.date, old); XCTAssertEqual(inverse.provider, direct.provider)
        let cross = try XCTUnwrap(Reports.resolvedRate(from: "USD", to: "GBP", rates: rates, on: .today))
        XCTAssertEqual(cross.value, "0.8"); XCTAssertEqual(cross.date, old); XCTAssertEqual(cross.provider, direct.provider)
        var mixed = rates; mixed[1].date = .today
        XCTAssertNil(try Reports.resolvedRate(from: "USD", to: "GBP", rates: mixed, on: .today))
        mixed[1].date = old; mixed[1].provider = "Другой источник"
        XCTAssertNil(try Reports.resolvedRate(from: "USD", to: "GBP", rates: mixed, on: .today))
        XCTAssertNil(try Reports.resolvedRate(from: "EUR", to: "RUB", rates: rates, on: .today))
    }
    func testSelectionLimitsDefaultsAndOldDecoding() throws {
        let data = try JSONEncoder().encode(Database())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var settings = try XCTUnwrap(json["settings"] as? [String: Any]); settings.removeValue(forKey: "dashboardCurrencies"); json["settings"] = settings
        let old = try JSONDecoder().decode(Database.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.settings.selectedDashboardCurrencies, ["RUB", "USD", "GBP"])
        var db = old; db.settings.dashboardCurrencies = []
        XCTAssertEqual(try JSONDecoder().decode(Database.self, from: JSONEncoder().encode(db)).settings.selectedDashboardCurrencies, [])
        db.settings.dashboardCurrencies = ["RUB", "USD", "GBP", "EUR", "JPY"]; XCTAssertNoThrow(try Ledger.validate(db))
        db.settings.dashboardCurrencies?.append("CHF"); XCTAssertThrowsError(try Ledger.validate(db))
        db.settings.dashboardCurrencies = ["USD", "USD"]; XCTAssertThrowsError(try Ledger.validate(db))
        db.settings.dashboardCurrencies = ["XXX"]; XCTAssertThrowsError(try Ledger.validate(db))
    }
    func testSelectedPairsWithoutAccountsAndEncryptedBackup() throws {
        var db = Database(); db.settings.dashboardCurrencies = ["RUB", "EUR", "JPY", "KWD", "GBP"]
        XCTAssertTrue(DashboardCurrencySelection.requestedCurrencies(db).isSuperset(of: ["EUR", "JPY", "KWD", "GBP"]))
        XCTAssertFalse(DashboardCurrencySelection.requestedCurrencies(db).contains("RUB"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VaultStore(url: root.appendingPathComponent("vault.beesave"))
        defer { store.close(); try? FileManager.default.removeItem(at: root) }
        let key = try VaultCrypto.random(), recovery = try VaultCrypto.random()
        try store.initialize(db: db, dataKey: key, bootstrap: Bootstrap(databaseID: db.id, password: nil, recovery: try VaultCrypto.seal(key, key: recovery, context: VaultCrypto.recoveryContext)))
        let copy = root.appendingPathComponent("copy.mubak"); try store.backup(to: copy)
        XCTAssertEqual(try VaultFile.read(Data(contentsOf: copy)).decrypt(key: key).settings.selectedDashboardCurrencies, db.settings.selectedDashboardCurrencies)
        try store.transaction { $0.settings.dashboardCurrencies = [] }; store.close(); try store.unlock(key: key)
        XCTAssertEqual(store.db?.settings.selectedDashboardCurrencies, [])
    }
}
