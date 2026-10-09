import XCTest
@testable import BudgetPresentation

final class DashboardRateFormatTests: XCTestCase {
    func testSmallPositiveRateDoesNotDisplayAsZeroAndMoneyScalesStayCorrect() {
        XCTAssertNotEqual(DisplayFormat.rate("0.000000123456789"), "0")
        XCTAssertTrue(DisplayFormat.rate("0.000000123456789").contains("123456"))
        XCTAssertEqual(DisplayFormat.money(3, currency: "JPY"), "3 JPY")
        XCTAssertEqual(DisplayFormat.money(1, currency: "KWD"), "0,001 KWD")
        XCTAssertEqual(DisplayFormat.money(-50, currency: "USD"), "-0,50 USD")
    }
}
