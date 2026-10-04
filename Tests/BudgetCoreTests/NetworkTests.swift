import XCTest
@testable import BudgetCore

final class NetworkTests: XCTestCase {
    func testLiveProvidersAC17() async throws {
        guard ProcessInfo.processInfo.environment["BEESAVE_NETWORK"] == "1" else { throw XCTSkip("Separate opt-in integration test") }
        let client = RateClient(); let rates = try await client.cbr()
        XCTAssertNotNil(try Reports.rate(from: "USD", to: "RUB", rates: rates, on: .today)); XCTAssertNotNil(try Reports.rate(from: "GBP", to: "RUB", rates: rates, on: .today))
        let data = try await client.download(RateProvider.frankfurterURL(base: "USD", quote: "GBP", on: nil)); let frank = try RateProvider.parseFrankfurter(data, base: "USD", quote: "GBP")
        XCTAssertGreaterThan(try Money.decimal(frank.rate), 0); print("LIVE CBR count=\(rates.count) effective=\(rates.first?.date.rawValue ?? "") Frankfurter USD/GBP effective=\(frank.date.rawValue)")
    }
}
