import XCTest
@testable import BudgetCore

final class KeychainTests: XCTestCase {
    func testSystemLocalKeychainRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["BEESAVE_KEYCHAIN"] == "1" else { throw XCTSkip("Separate local system integration test") }
        let id = UUID(), key = try VaultCrypto.random()
        defer { LocalKeys.remove(id: id, biometric: false) }
        try LocalKeys.put(key, id: id, biometric: false)
        XCTAssertEqual(try LocalKeys.get(id: id, biometric: false), key)
        LocalKeys.remove(id: id, biometric: false)
        XCTAssertThrowsError(try LocalKeys.get(id: id, biometric: false))
    }
}
