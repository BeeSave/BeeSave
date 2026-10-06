import XCTest
import CoreGraphics
import ImageIO
@testable import BudgetCore

final class FinancialAccountTests: XCTestCase {
    private func day(_ value: String) throws -> Day { try Day(value) }
    private func fixture(_ kind: AccountKind, principal: Int64, start: String = "2024-01-01", end: String? = "2025-01-01", rate: String? = "12", basis: InterestBasis = .equalMonths) throws -> (Database, FinancialContract, Account) {
        var db = Database(); var account = Account(name: "Договор", currency: "RUB", openedOn: try day(start)); account.financialKind = kind
        try Ledger.saveAccount(account, opening: kind.isDebt ? -principal : principal, in: &db)
        let payment = Account(name: "Оплата", currency: "RUB", openedOn: try day(start)); try Ledger.saveAccount(payment, opening: 100_000_000, in: &db)
        var contract = FinancialContract(accountID: account.id, kind: kind, start: try day(start), end: try end.map(day), annualPercent: rate); contract.originalPrincipal = principal; contract.paymentAccountID = payment.id; contract.terms[0].basis = basis
        try FinancialLedger.saveContract(contract, in: &db); try Ledger.validate(db)
        return (db, contract, payment)
    }
    func testLimitIsNotAnAssetAndPurchaseAndRepaymentAreCountedOnce() throws {
        var (db, contract, cash) = try fixture(.revolvingCredit, principal: 0, end: nil)
        contract.terms[0].credit.limit = 10_000_000; contract.terms[0].credit.chargesUseLimit = false; try FinancialLedger.saveContract(contract, in: &db)
        let before = try db.accounts.reduce(Int64(0)) { try Money.add($0, db.balance($1.id)) }
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: db).available, 10_000_000)
        XCTAssertEqual(before, 100_000_000)
        try Ledger.saveOperation(Operation(kind: .expense, date: day("2024-01-02"), accountID: contract.accountID, amount: 3_000_000), in: &db)
        var debt = try FinancialLedger.debt(accountID: contract.accountID, db: db); XCTAssertEqual(debt.debt, 3_000_000); XCTAssertEqual(debt.available, 7_000_000)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 1_000_000, date: day("2024-01-03"), in: &db)
        debt = try FinancialLedger.debt(accountID: contract.accountID, db: db); XCTAssertEqual(debt.debt, 2_000_000); XCTAssertEqual(debt.available, 8_000_000)
        XCTAssertEqual(db.operations.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }, 3_000_000)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 2_100_000, date: day("2024-01-04"), in: &db)
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: db).ownFunds, 100_000)
    }
    func testDailyDepositAndConfirmationAndDuplicateProtection() throws {
        var (db, contract, _) = try fixture(.deposit, principal: 100_000_000, end: "2024-01-31", basis: .actual365)
        contract.frequency = .maturity; contract.terms[0].deposit.capitalize = true; try FinancialLedger.saveContract(contract, in: &db)
        let row = try XCTUnwrap(FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01")).first { $0.kind == .depositInterest })
        XCTAssertEqual(row.amount, 986_301); XCTAssertEqual(try db.balance(contract.accountID), 100_000_000)
        try FinancialLedger.confirmDeposit(contractID: contract.id, eventID: row.id, gross: 986_301, date: day("2024-01-31"), in: &db)
        XCTAssertEqual(try db.balance(contract.accountID), 100_986_301)
        XCTAssertThrowsError(try FinancialLedger.confirmDeposit(contractID: contract.id, eventID: row.id, gross: 986_301, date: day("2024-01-31"), in: &db))
        XCTAssertEqual(db.operations.filter { $0.kind == .income }.count, 1)
    }
    func testMonthlyCapitalizationAndExternalPayment() throws {
        var (db, contract, cash) = try fixture(.deposit, principal: 10_000_000)
        var rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01"))
        XCTAssertEqual(rows.filter { $0.kind == .depositInterest }.compactMap(\.amount).reduce(0, +), 1_200_000)
        contract.terms[0].deposit.capitalize = true; try FinancialLedger.saveContract(contract, in: &db)
        rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01"))
        XCTAssertEqual(rows.first { $0.kind == .depositMaturity }?.amount, 11_268_251)
        let row = try XCTUnwrap(rows.first { $0.kind == .depositInterest })
        try FinancialLedger.confirmDeposit(contractID: contract.id, eventID: row.id, gross: 100_000, tax: 10_000, payoutAccountID: cash.id, date: day("2024-02-01"), in: &db)
        XCTAssertEqual(try db.balance(contract.accountID), 10_000_000)
        XCTAssertEqual(try db.balance(cash.id), 100_090_000)
        XCTAssertEqual(db.operations.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }, 100_000)
        XCTAssertEqual(db.operations.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }, 10_000)
    }
    func testSeparateDepositCapitalizationAndSingleFinalPayout() throws {
        var (db, contract, _) = try fixture(.deposit, principal: 10_000_000)
        contract.frequency = .maturity; contract.terms[0].deposit.capitalize = true
        contract.terms[0].deposit.accrualFrequency = .monthly; contract.terms[0].deposit.capitalizationFrequency = .monthly
        contract.terms[0].deposit.roundOnlyAtFinalPayout = true
        try FinancialLedger.saveContract(contract, in: &db)
        let before = db
        var rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01"))
        let interest = try XCTUnwrap(rows.first { $0.kind == .depositInterest })
        XCTAssertEqual(rows.filter { $0.kind == .depositInterest }.count, 1)
        XCTAssertEqual(interest.amount, 1_268_250); XCTAssertEqual(interest.accuracy, .calculated)
        XCTAssertEqual(rows.first { $0.kind == .depositMaturity }?.amount, 11_268_250)
        XCTAssertEqual(db, before)
        contract.terms[0].deposit.roundOnlyAtFinalPayout = false; try FinancialLedger.saveContract(contract, in: &db)
        rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01"))
        XCTAssertEqual(rows.first { $0.kind == .depositMaturity }?.amount, 11_268_251)
        contract.terms[0].deposit.capitalizationFrequency = .quarterly; contract.terms[0].deposit.roundOnlyAtFinalPayout = true
        try FinancialLedger.saveContract(contract, in: &db)
        rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01"))
        XCTAssertEqual(rows.first { $0.kind == .depositMaturity }?.amount, 11_255_088)
        contract.terms[0].deposit.capitalizationFrequency = .monthly; try FinancialLedger.saveContract(contract, in: &db)
        try FinancialLedger.confirmDeposit(contractID: contract.id, eventID: interest.id, gross: 1_268_250, date: day("2025-01-01"), in: &db)
        XCTAssertEqual(try db.balance(contract.accountID), 11_268_250)
        rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2025-01-01"))
        XCTAssertEqual(rows.first { $0.kind == .depositMaturity }?.amount, 11_268_250)
        XCTAssertTrue(rows.first { $0.kind == .depositInterest }!.isFulfilled)
    }
    func testAnnuityFinalPaymentAndZeroRate() throws {
        var (db, contract, _) = try fixture(.mortgage, principal: 10_000_000)
        var rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01")).filter { $0.kind == .loanPayment }
        XCTAssertEqual(rows.count, 12); XCTAssertEqual(rows[0].amount, 888_488); XCTAssertEqual(rows[0].amount(.interest), 100_000); XCTAssertEqual(rows[0].balanceAfter, 9_211_512)
        XCTAssertEqual(rows.last?.amount, 888_485); XCTAssertEqual(rows.last?.balanceAfter, 0)
        contract.terms[0].annualPercent = "0"; try FinancialLedger.saveContract(contract, in: &db)
        rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01"))
        XCTAssertEqual(rows.reduce(0) { $0 + $1.amount(.interest) }, 0); XCTAssertEqual(rows.last?.balanceAfter, 0); XCTAssertEqual(rows.reduce(0) { $0 + $1.amount(.principal) }, 10_000_000)
    }
    func testMortgagePaymentDoesNotDoubleCountInterest() throws {
        var (db, contract, cash) = try fixture(.mortgage, principal: 300_000_000)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 3_000_000, interestCharge: 2_000_000, date: day("2024-02-01"), in: &db)
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: db).debt, 299_000_000)
        XCTAssertEqual(db.operations.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }, 2_000_000)
        var charge = Operation(kind: .expense, date: try day("2024-02-02"), accountID: contract.accountID, amount: 2_000_000); charge.financial = FinanceOperationDetails(component: .interest); try Ledger.saveOperation(charge, in: &db)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 3_000_000, date: day("2024-02-03"), in: &db)
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: db).debt, 298_000_000)
        XCTAssertEqual(db.operations.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }, 4_000_000)
    }
    func testDeletingOneMemberDeletesWholeFinancialGroup() throws {
        var (db, contract, cash) = try fixture(.mortgage, principal: 10_000_000)
        let original = db
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 888_488, interestCharge: 100_000, date: day("2024-02-01"), in: &db)
        let group = try XCTUnwrap(db.financeData.groups.last)
        XCTAssertThrowsError(try Ledger.saveOperation(db.operations.first { $0.id == group.operationIDs[0] }!, in: &db))
        try Ledger.deleteOperation(group.operationIDs[0], in: &db)
        XCTAssertEqual(try db.balance(contract.accountID), try original.balance(contract.accountID)); XCTAssertTrue(db.financeData.groups.isEmpty)
        XCTAssertEqual(db.operations.count, original.operations.count)
    }
    func testFailedFinancialGroupIsAtomic() throws {
        var (db, contract, cash) = try fixture(.mortgage, principal: 10_000_000); let before = db
        XCTAssertThrowsError(try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 888_488, interestCharge: 100_000, allocations: [FinancialAllocation(.principal, 9_999_999)], date: day("2024-02-01"), in: &db))
        XCTAssertEqual(db, before)
    }
    func testMinimumPaymentAndGraceAreSeparateAndEventsStable() throws {
        var (db, contract, cash) = try fixture(.revolvingCredit, principal: 3_000_000, end: nil)
        let statement = CreditStatement(contractID: contract.id, start: try day("2024-01-01"), closedOn: try day("2024-01-31"), dueOn: try day("2024-02-20"), balance: 3_000_000, minimum: 150_000, graceAmount: 3_000_000)
        db.financeData.statements.append(statement)
        try Ledger.saveOperation(Operation(kind: .expense, date: day("2024-02-02"), accountID: contract.accountID, amount: 500_000), in: &db)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 150_000, date: day("2024-02-03"), in: &db)
        var rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-02-04"))
        XCTAssertEqual(rows.first { $0.kind == .minimumPayment }?.remaining, 0); XCTAssertEqual(rows.first { $0.kind == .gracePayment }?.remaining, 2_850_000)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 2_850_000, date: day("2024-02-20"), in: &db)
        rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-02-20"))
        XCTAssertEqual(rows.first { $0.kind == .gracePayment }?.remaining, 0); XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: db).debt, 500_000)
        db.financeData.statements = []; contract.terms[0].credit.closingDay = 1; try FinancialLedger.saveContract(contract, in: &db)
        let one = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-02-04")), two = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-02-04"))
        XCTAssertEqual(one.map(\.id), two.map(\.id))
    }
    func testGracePaymentCannotIgnoreARequiredLargerMinimum() throws {
        var (db, contract, cash) = try fixture(.revolvingCredit, principal: 3_000_000, end: nil)
        db.financeData.statements = [try CreditStatement(contractID: contract.id, start: day("2024-01-01"), closedOn: day("2024-01-31"), dueOn: day("2024-02-20"), balance: 3_000_000, minimum: 1_000_000, graceAmount: 500_000)]
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 500_000, date: day("2024-02-15"), in: &db)
        var rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-02-16"))
        XCTAssertFalse(rows.first { $0.kind == .gracePayment }!.isFulfilled)
        XCTAssertEqual(rows.first { $0.kind == .gracePayment }?.accuracy, .incomplete)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 500_000, date: day("2024-02-20"), in: &db)
        rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-02-20"))
        XCTAssertTrue(rows.first { $0.kind == .gracePayment }!.isFulfilled)
    }
    func testLateCreditCostAndUnknownRate() throws {
        var (db, contract, _) = try fixture(.revolvingCredit, principal: 3_000_000, end: nil, rate: "36.5", basis: .actual365)
        contract.terms[0].credit.grace = .manual; contract.terms[0].credit.graceEnd = try day("2024-01-20"); contract.terms[0].credit.accrualAfterGrace = .afterDeadline; try FinancialLedger.saveContract(contract, in: &db)
        let early = try FinancialEngine.creditCost(contract: contract, db: db, paymentDate: day("2024-01-20"), asOf: day("2024-01-01")); XCTAssertEqual(early.total, 0)
        let late = try FinancialEngine.creditCost(contract: contract, db: db, paymentDate: day("2024-01-31"), asOf: day("2024-01-01")); XCTAssertEqual(late.interest, 30_000)
        contract.terms[0].annualPercent = nil; try FinancialLedger.saveContract(contract, in: &db)
        XCTAssertNil(try FinancialEngine.creditCost(contract: contract, db: db, paymentDate: day("2024-01-31"), asOf: day("2024-01-01")).total)
        XCTAssertEqual(db.operations.filter { $0.kind == .expense }.count, 0)
    }
    func testCalendarAnchorsAndBusinessDayRules() throws {
        let (_, contract, _) = try fixture(.mortgage, principal: 10_000, start: "2024-01-31", end: "2024-04-30")
        XCTAssertEqual(try FinanceMath.paymentDates(contract, through: day("2024-04-30")).map(\.rawValue), ["2024-02-29", "2024-03-31", "2024-04-30"])
        let calendar = BankCalendar(name: "Test", years: [2024], holidays: [try day("2024-04-01")])
        XCTAssertEqual(try FinanceMath.shifted(day("2024-03-31"), rule: .following, calendar: calendar).0, try day("2024-04-02"))
        XCTAssertEqual(try FinanceMath.shifted(day("2024-03-31"), rule: .modifiedFollowing, calendar: calendar).0, try day("2024-03-29"))
        XCTAssertFalse(try FinanceMath.shifted(day("2025-01-01"), rule: .following, calendar: calendar).1)
        XCTAssertEqual(try FinanceMath.fraction(day("2024-02-28"), day("2024-03-01"), basis: .actualActual), Decimal(2) / 366)
        XCTAssertNotEqual(try FinanceMath.fraction(day("2024-02-29"), day("2024-03-31"), basis: .thirtyE360), try FinanceMath.fraction(day("2024-02-29"), day("2024-03-31"), basis: .thirtyUS360))
    }
    func testInterestOnlyAndPrepaymentScenariosDoNotChangeFacts() throws {
        var (db, contract, _) = try fixture(.mortgage, principal: 10_000_000)
        contract.terms[0].loan.method = .interestOnly; try FinancialLedger.saveContract(contract, in: &db)
        let rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01"))
        XCTAssertEqual(rows.first?.amount(.principal), 0); XCTAssertEqual(rows.last?.amount(.principal), 10_000_000); XCTAssertEqual(rows.last?.balanceAfter, 0)
        contract.terms[0].loan.method = .annuity; contract.terms[0].loan.prepaymentFeePercent = "0"; try FinancialLedger.saveContract(contract, in: &db); let before = db
        let reducedTerm = try FinancialEngine.prepayment(contract: contract, db: db, amount: 2_000_000, mode: .reduceTerm, asOf: day("2024-01-01"))
        let reducedPayment = try FinancialEngine.prepayment(contract: contract, db: db, amount: 2_000_000, mode: .reducePayment, asOf: day("2024-01-01"))
        XCTAssertLessThan(reducedTerm.events.count, reducedPayment.events.count); XCTAssertEqual(reducedPayment.end, contract.end); XCTAssertEqual(db, before)
    }
    func testConfirmedPrepaymentKeepsModeAndCanBeDeletedWithoutLosingHistory() throws {
        var (base, contract, cash) = try fixture(.mortgage, principal: 10_000_000)
        contract.terms[0].loan.paymentOverride = 888_488; try FinancialLedger.saveContract(contract, in: &base)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 888_488, interestCharge: 100_000, date: day("2024-02-01"), in: &base)
        let original = try FinancialEngine.events(contract: contract, db: base, asOf: day("2024-02-01")).filter { $0.date > (try! day("2024-02-01")) }
        var shorter = base
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 2_020_000, feeCharge: 20_000, date: day("2024-02-01"), prepayment: true, prepaymentMode: .reduceTerm, in: &shorter)
        let firstGroup = try XCTUnwrap(shorter.financeData.groups.last)
        let firstTransfer = try XCTUnwrap(shorter.operations.first { $0.financial?.groupID == firstGroup.id && $0.kind == .transfer })
        XCTAssertEqual(firstTransfer.financial?.prepaymentMode, .reduceTerm)
        XCTAssertEqual(firstTransfer.financial?.prepaymentRegularPayment, 888_488)
        var shorterRows = try FinancialEngine.events(contract: contract, db: shorter, asOf: day("2024-02-01")).filter { $0.date > (try! day("2024-02-01")) }
        XCTAssertEqual(shorterRows.first?.amount, 888_488); XCTAssertLessThan(try XCTUnwrap(shorterRows.last?.date), try XCTUnwrap(original.last?.date))
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: shorter).amount(.principal), 7_211_512)
        XCTAssertEqual(shorter.operations.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }, 120_000)
        var lower = base
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 2_000_000, date: day("2024-02-01"), prepayment: true, prepaymentMode: .reducePayment, in: &lower)
        let lowerRows = try FinancialEngine.events(contract: contract, db: lower, asOf: day("2024-02-01")).filter { $0.date > (try! day("2024-02-01")) }
        XCTAssertLessThan(try XCTUnwrap(lowerRows.first?.amount), 888_488); XCTAssertEqual(lowerRows.last?.date, original.last?.date)
        let previousEnd = shorterRows.last?.date
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 1_000_000, date: day("2024-02-02"), prepayment: true, prepaymentMode: .reducePayment, in: &shorter)
        let secondGroup = try XCTUnwrap(shorter.financeData.groups.last)
        shorterRows = try FinancialEngine.events(contract: contract, db: shorter, asOf: day("2024-02-02")).filter { $0.date > (try! day("2024-02-02")) }
        XCTAssertEqual(shorterRows.last?.date, previousEnd); XCTAssertLessThan(try XCTUnwrap(shorterRows.first?.amount), 888_488)
        try FinancialLedger.deleteGroup(secondGroup.id, in: &shorter); try FinancialLedger.deleteGroup(firstGroup.id, in: &shorter)
        XCTAssertEqual(shorter.operations, base.operations)
        XCTAssertEqual(try FinancialEngine.events(contract: contract, db: shorter, asOf: day("2024-02-01")).filter { $0.date > (try! day("2024-02-01")) }, original)
    }
    func testBulkForecastRetainsTransfersBetweenFinancialAccounts() throws {
        var (db, deposit, _) = try fixture(.deposit, principal: 100_000_000)
        var account = Account(name: "Ипотека", currency: "RUB", openedOn: try day("2024-01-01")); account.financialKind = .mortgage
        try Ledger.saveAccount(account, opening: -10_000_000, in: &db)
        var loan = FinancialContract(accountID: account.id, kind: .mortgage, start: try day("2024-01-01"), end: try day("2025-01-01"), annualPercent: "12"); loan.terms[0].basis = .equalMonths
        try FinancialLedger.saveContract(loan, in: &db)
        try FinancialLedger.payDebt(contractID: loan.id, from: deposit.accountID, amount: 888_488, interestCharge: 100_000, date: day("2024-02-01"), in: &db)
        let date = try day("2024-02-02")
        var full: [FinanceEvent] = []
        for contract in db.financeData.contracts { full.append(contentsOf: try FinancialEngine.events(contract: contract, db: db, asOf: date)) }
        full.sort { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        XCTAssertEqual(try FinancialEngine.events(db: db, asOf: day("2024-02-02")), full)
        var projection = db; projection.operations = FinancialLedger.operationsByAccount(in: db)[loan.accountID] ?? []
        XCTAssertEqual(try FinancialLedger.debt(accountID: loan.accountID, db: projection), try FinancialLedger.debt(accountID: loan.accountID, db: db))
    }
    func testUnallocatedCorrectionPreventsPreciseForecast() throws {
        var (db, contract, _) = try fixture(.mortgage, principal: 10_000_000)
        _ = try Ledger.reconcile(accountID: contract.accountID, observed: -10_100_000, reason: "Сверка банка", in: &db)
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: db).amount(.unallocated), 100_000)
        XCTAssertTrue(try FinancialEngine.events(contract: contract, db: db).allSatisfy { $0.accuracy == .incomplete })
    }
    func testLegacyOptionalFieldsAndMigrationPreserveHistory() throws {
        var old = Database(); old.version = 1
        let account = Account(name: "До обновления", currency: "RUB", openedOn: try day("2024-01-01")); try Ledger.saveAccount(account, opening: -100, in: &old)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any]); json.removeValue(forKey: "finances")
        let decoded = try JSONDecoder().decode(Database.self, from: JSONSerialization.data(withJSONObject: json))
        let migrated = try FinancialLedger.migrate(decoded); XCTAssertEqual(migrated.version, 2); XCTAssertEqual(migrated.accounts.first?.kind, .ordinary); XCTAssertEqual(try migrated.balance(account.id), -100); XCTAssertEqual(migrated.operations, old.operations)
        var invalid = migrated; invalid.version = 3; XCTAssertThrowsError(try Ledger.validate(invalid))
    }
    func testMigrationWritesVerifiedOriginalBackupAndFailsWithoutChangingSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("finance-migration-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultStore(url: root.appendingPathComponent("vault.beesave")); var old = Database(); old.version = 1
        let key = try VaultCrypto.random(), recovery = try VaultCrypto.random(); let bootstrap = Bootstrap(databaseID: old.id, password: nil, recovery: try VaultCrypto.seal(key, key: recovery, context: VaultCrypto.recoveryContext))
        try store.initialize(db: old, dataKey: key, bootstrap: bootstrap); let bytes = try Data(contentsOf: store.url); store.close(); store.beforeWrite = { throw BudgetError.storage("Injected failure") }
        XCTAssertThrowsError(try store.unlock(key: key)); XCTAssertEqual(try Data(contentsOf: store.url), bytes); XCTAssertNil(store.db)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Backups.noindex"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1); XCTAssertEqual(try VaultFile.read(Data(contentsOf: backups[0])).decrypt(key: key), old)
        store.beforeWrite = nil; try store.unlock(key: key); XCTAssertEqual(store.db?.version, 2)
    }
    func testManualBankAndImageValidation() throws {
        var db = Database(); let bank = UserBank(name: "Мой банк", country: .gb); try FinancialLedger.saveBank(bank, in: &db)
        XCTAssertEqual(db.financialBankName(bank.id), "Мой банк"); var unsafe = bank; unsafe.logo = Data("<svg onload='bad'>".utf8); XCTAssertThrowsError(try FinancialLedger.saveBank(unsafe, in: &db))
        let encoded = try JSONEncoder().encode(db); XCTAssertEqual(try JSONDecoder().decode(Database.self, from: encoded), db)
    }
    func testFinancialCSVRoundTripAndRejectsPartialGroups() throws {
        var (db, contract, cash) = try fixture(.mortgage, principal: 300_000_000)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 3_000_000, interestCharge: 2_000_000, date: day("2024-02-01"), in: &db)
        let data = try CSVCodec.export(db.operations, db: db)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix(CSVCodec.financialHeaders.joined(separator: ",")))
        var options = ImportOptions(); options.createReferences = true
        let preview = try CSVImporter.preview(data: data, options: options, db: Database())
        XCTAssertTrue(preview.canCommit, preview.issues.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: preview.database), try FinancialLedger.debt(accountID: contract.accountID, db: db))
        XCTAssertEqual(preview.database.financeData.groups, db.financeData.groups)
        XCTAssertEqual(preview.database.contract(for: contract.accountID)?.status, .draft)
        XCTAssertNil(preview.database.contract(for: contract.accountID)?.terms[0].annualPercent)
        let repeated = try CSVImporter.preview(data: data, options: options, db: preview.database)
        XCTAssertTrue(repeated.added.isEmpty); XCTAssertEqual(repeated.database.financeData.groups.count, 1)
        let member = try XCTUnwrap(db.operations.first { $0.financial?.groupID != nil })
        XCTAssertThrowsError(try CSVCodec.export([member], db: db))
        let parsed = try CSVCodec.parse(String(decoding: data, as: UTF8.self))
        let partial = Data((parsed.dropLast().map { $0.fields.map(CSVCodec.quote).joined(separator: ",") }.joined(separator: "\n") + "\n").utf8)
        XCTAssertFalse(try CSVImporter.preview(data: partial, options: options, db: Database()).canCommit)
        options.excludedRows = [parsed.count - 1]
        let excludedGroup = try CSVImporter.preview(data: data, options: options, db: Database())
        XCTAssertTrue(excludedGroup.canCommit); XCTAssertEqual(excludedGroup.excludedFinancialGroups, 1); XCTAssertTrue(excludedGroup.database.financeData.groups.isEmpty)
    }
    func testReminderWindowDeduplicationTimeZoneAndFulfillment() throws {
        var (db, contract, _) = try fixture(.deposit, principal: 10_000_000)
        contract.timeZoneID = "Europe/London"; contract.reminders.interestEnabled = true; contract.reminders.paymentOffsets = [1, 1, 0]
        try FinancialLedger.saveContract(contract, in: &db)
        var book = db.financeData; book.reminders.systemEnabled = true; db.finances = book
        let now = try day("2024-01-01").date
        let events = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01"))
        let plan = try FinancialReminderPlanner.plan(db: db, events: events, now: now)
        XCTAssertEqual(plan.count, 2); XCTAssertEqual(Set(plan.map(\.id)).count, 2)
        XCTAssertEqual(plan.first?.fireAt, try day("2024-01-31").date.addingTimeInterval(9 * 3600))
        XCTAssertFalse(plan[0].id.contains(contract.id.uuidString)); XCTAssertFalse(plan[0].databaseToken.contains(db.id.uuidString))
        XCTAssertEqual(try FinancialReminderPlanner.plan(db: db, events: events, now: now, delivered: Set(plan.map(\.id))).count, 0)
        XCTAssertEqual(try FinancialReminderPlanner.plan(db: db, events: events, now: now, limit: 1).count, 1)
        let event = try XCTUnwrap(events.first { $0.kind == .depositInterest })
        try FinancialLedger.confirmDeposit(contractID: contract.id, eventID: event.id, gross: event.amount!, date: event.date, in: &db)
        let refreshed = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-02-01"))
        XCTAssertFalse(try FinancialReminderPlanner.plan(db: db, events: refreshed, now: now).contains { $0.eventToken == event.id })
    }
    func testManualRepaymentIsRequiredAndCannotSpillIntoOtherLots() throws {
        var (db, contract, cash) = try fixture(.revolvingCredit, principal: 3_000_000, end: nil)
        contract.terms[0].credit.repaymentOrder = .manual; try FinancialLedger.saveContract(contract, in: &db)
        let before = db
        XCTAssertThrowsError(try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 100_000, date: day("2024-01-02"), in: &db)); XCTAssertEqual(before, db)
        XCTAssertThrowsError(try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 100_000, allocations: [FinancialAllocation(.principal, 100_000, lotID: UUID())], date: day("2024-01-02"), in: &db)); XCTAssertEqual(before, db)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 100_000, allocations: [FinancialAllocation(.principal, 100_000)], date: day("2024-01-02"), in: &db)
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: db).debt, 2_900_000)
    }

    func testEscrowCombinedPaymentIsAtomicAndNotDoubleExpense() throws {
        var (db, contract, cash) = try fixture(.mortgage, principal: 300_000_000)
        let escrow = Account(name: "Escrow", currency: "RUB", openedOn: contract.start); try Ledger.saveAccount(escrow, in: &db)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 3_500_000, interestCharge: 2_000_000, escrowAmount: 500_000, escrowAccountID: escrow.id, date: day("2024-02-01"), in: &db)
        XCTAssertEqual(try db.balance(cash.id), 96_500_000); XCTAssertEqual(try db.balance(escrow.id), 500_000)
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: db).amount(.principal), 299_000_000)
        XCTAssertEqual(db.operations.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }, 2_000_000)
        try Ledger.saveOperation(Operation(kind: .expense, date: day("2024-02-02"), accountID: escrow.id, amount: 500_000), in: &db)
        XCTAssertEqual(db.operations.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }, 2_500_000)
        let before = db
        XCTAssertThrowsError(try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 3_500_000, interestCharge: 2_000_000, escrowAmount: 500_000, escrowAccountID: contract.accountID, date: day("2024-03-01"), in: &db)); XCTAssertEqual(before, db)
    }
    func testDebtReportsIncludeArchivedAndForecastsDoNotChangeFacts() throws {
        var (db, contract, _) = try fixture(.mortgage, principal: 10_000_000)
        let index = try XCTUnwrap(db.accounts.firstIndex { $0.id == contract.accountID }); db.accounts[index].archived = true
        var report = Report(name: "Долг"); report.dataset = .debt; report.metric = .principal; report.grouping = .account; report.filters = Filters(); report.filters.includeArchived = false
        let rows = try FinancialReports.rows(report, db: db, asOf: day("2024-01-01")); XCTAssertEqual(try Reports.total(rows).known, 10_000_000)
        report.dataset = .financialPlan; report.metric = .payment; report.filters.start = try day("2024-01-01"); report.filters.end = try day("2025-01-01")
        let before = db; XCTAssertFalse(try FinancialReports.rows(report, db: db, asOf: day("2024-01-01")).isEmpty); XCTAssertEqual(before, db)
        report.currency = "GBP"; XCTAssertTrue(try Reports.total(FinancialReports.rows(report, db: db, asOf: day("2024-01-01"))).partial)
    }

    func testEarlyDepositReturnPreservesIncomeAndDeductsAdjustmentOnce() throws {
        var (db, contract, cash) = try fixture(.deposit, principal: 10_000_000, basis: .actual365)
        contract.terms[0].deposit.earlyAnnualPercent = "0"; contract.terms[0].deposit.earlyFee = 10_000; try FinancialLedger.saveContract(contract, in: &db)
        let event = try XCTUnwrap(FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01")).first { $0.kind == .depositInterest })
        try FinancialLedger.confirmDeposit(contractID: contract.id, eventID: event.id, gross: 100_000, payoutAccountID: cash.id, date: day("2024-02-01"), in: &db)
        let scenario = try FinancialEngine.depositExit(contract: contract, db: db, exitOn: day("2024-03-01"), asOf: day("2024-03-01"))
        XCTAssertEqual(scenario.previouslyPaidInterest, 100_000); XCTAssertEqual(scenario.recomputedInterest, 0); XCTAssertEqual(scenario.interestAdjustment, -100_000); XCTAssertEqual(scenario.returnBeforeNewTax, 9_890_000)
        try FinancialLedger.closeDeposit(contract.id, to: cash.id, interestAdjustment: scenario.interestAdjustment!, fee: scenario.fee, date: day("2024-03-01"), in: &db)
        XCTAssertEqual(try db.balance(contract.accountID), 0); XCTAssertEqual(try db.balance(cash.id), 109_990_000)
        XCTAssertEqual(db.operations.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }, 100_000)
        XCTAssertEqual(db.operations.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }, 110_000)
        XCTAssertEqual(db.contract(for: contract.accountID)?.status, .closed)
        let group = try XCTUnwrap(db.financeData.groups.last); try FinancialLedger.deleteGroup(group.id, in: &db)
        XCTAssertEqual(try db.balance(contract.accountID), 10_000_000); XCTAssertEqual(db.contract(for: contract.accountID)?.status, .active)
    }
    func testRenewalKeepsPastConditionsAndUnknownRateDoesNotBecomeZero() throws {
        var (db, contract, _) = try fixture(.deposit, principal: 10_000_000)
        try FinancialLedger.renewDeposit(contract.id, start: day("2025-01-01"), end: day("2026-01-01"), annualPercent: nil, in: &db)
        let renewed = try XCTUnwrap(db.contract(for: contract.accountID))
        XCTAssertEqual(renewed.previousPeriods?.first?.start, contract.start); XCTAssertEqual(renewed.previousPeriods?.first?.terms.first?.annualPercent, "12")
        XCTAssertTrue(try FinancialEngine.events(contract: renewed, db: db, asOf: day("2025-01-01")).filter { $0.kind == .depositInterest }.allSatisfy { $0.amount == nil && $0.accuracy == .incomplete })
        XCTAssertEqual(try db.balance(contract.accountID), 10_000_000)
    }
    func testReplacingFinancialGroupFailureRestoresAllOriginalFacts() throws {
        var (db, contract, cash) = try fixture(.mortgage, principal: 300_000_000)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 3_000_000, interestCharge: 2_000_000, date: day("2024-02-01"), in: &db)
        let group = try XCTUnwrap(db.financeData.groups.last), before = db
        XCTAssertThrowsError(try FinancialLedger.replaceGroup(group.id, in: &db) { candidate in try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 0, date: day("2024-02-01"), in: &candidate) }); XCTAssertEqual(db, before)
        try FinancialLedger.replaceGroup(group.id, in: &db) { candidate in try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 4_000_000, interestCharge: 2_000_000, date: day("2024-02-01"), in: &candidate) }
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: db).amount(.principal), 298_000_000); XCTAssertEqual(db.financeData.groups.count, 1)
    }
    func testNominalDailyAnnuityClosesPrincipalAndExcessRepaysHighestRate() throws {
        var (db, contract, cash) = try fixture(.mortgage, principal: 10_000_000, basis: .actual365)
        let rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01"))
        XCTAssertEqual(rows.last?.balanceAfter, 0); XCTAssertTrue(rows.allSatisfy { $0.amount != nil })
        (db, contract, cash) = try fixture(.revolvingCredit, principal: 0, end: nil)
        var purchase = Operation(kind: .expense, date: try day("2024-01-02"), accountID: contract.accountID, amount: 100_000); purchase.financial = FinanceOperationDetails(); purchase.financial?.transactionKind = .purchase; try Ledger.saveOperation(purchase, in: &db)
        var advance = Operation(kind: .expense, date: try day("2024-01-03"), accountID: contract.accountID, amount: 100_000); advance.financial = FinanceOperationDetails(); advance.financial?.transactionKind = .cash; try Ledger.saveOperation(advance, in: &db)
        contract.terms[0].credit.excessRepaymentOrder = .highestRate; contract.terms[0].credit.buckets[0].annualPercent = "12"; contract.terms[0].credit.buckets[1].annualPercent = "48"; try FinancialLedger.saveContract(contract, in: &db)
        var book = db.financeData; book.statements.append(CreditStatement(contractID: contract.id, start: try day("2024-01-01"), closedOn: try day("2024-01-10"), dueOn: try day("2024-01-20"), balance: 200_000, minimum: 50_000, graceAmount: 100_000)); db.finances = book
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 100_000, date: day("2024-01-12"), in: &db)
        let lots = try FinancialLedger.creditLots(accountID: contract.accountID, db: db)
        XCTAssertEqual(lots.first { $0.kind == .purchase }?.amount, 50_000); XCTAssertEqual(lots.first { $0.kind == .cash }?.amount, 50_000)
    }

    func testImportedMortgagePaymentSplitsExpenseAndIsIdempotent() throws {
        let (db, contract, cash) = try fixture(.mortgage, principal: 300_000_000)
        let data = Data("date,type,account_name,currency,amount,comment\n2024-02-01,expense,Оплата,RUB,30000,Банк\n".utf8)
        var options = ImportOptions(); options.accountMapping["Оплата"] = cash.id
        var mapping = CSVFinancialPayment(contractID: contract.id); mapping.interest = 2_000_000; options.financialPayments[1] = mapping
        let preview = try CSVImporter.preview(data: data, options: options, db: db)
        XCTAssertTrue(preview.canCommit, preview.issues.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(preview.added.count, 2)
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: preview.database).amount(.principal), 299_000_000)
        XCTAssertEqual(try preview.database.balance(cash.id), 97_000_000)
        XCTAssertEqual(preview.database.operations.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }, 2_000_000)
        XCTAssertEqual(db.operations.count, 2)
        let repeated = try CSVImporter.preview(data: data, options: options, db: preview.database)
        XCTAssertTrue(repeated.canCommit); XCTAssertTrue(repeated.added.isEmpty); XCTAssertEqual(repeated.skipped, 1)
        let reformatted = Data((String(decoding: data, as: UTF8.self) + "\n").utf8)
        let probable = try CSVImporter.preview(data: reformatted, options: options, db: preview.database)
        XCTAssertEqual(probable.probable, [1]); XCTAssertTrue(probable.added.isEmpty)
        mapping.interest = 1_000_000; options.financialPayments[1] = mapping
        XCTAssertFalse(try CSVImporter.preview(data: data, options: options, db: preview.database).canCommit)
        options.financialPayments[1]?.allocations = [FinancialAllocation(.principal, 1)]
        XCTAssertFalse(try CSVImporter.preview(data: data, options: options, db: db).canCommit)
        options.excludedRows = [1]
        XCTAssertTrue(try CSVImporter.preview(data: data, options: options, db: db).added.isEmpty)
    }
    func testEditedImportedPaymentCannotBeImportedAgain() throws {
        let (db, contract, cash) = try fixture(.mortgage, principal: 300_000_000)
        let data = Data("date,type,account_name,currency,amount\n2024-02-01,expense,Оплата,RUB,30000\n".utf8)
        var options = ImportOptions(); options.accountMapping["Оплата"] = cash.id
        var mapping = CSVFinancialPayment(contractID: contract.id); mapping.interest = 2_000_000; options.financialPayments[1] = mapping
        var imported = try CSVImporter.preview(data: data, options: options, db: db).database
        let original = try XCTUnwrap(imported.financeData.groups.last)
        try FinancialLedger.replaceGroup(original.id, in: &imported) {
            try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 3_000_000, interestCharge: 1_900_000, date: day("2024-02-01"), in: &$0)
        }
        XCTAssertEqual(imported.financeData.groups.last?.importSourceKey, original.importSourceKey)
        let before = imported
        let repeated = try CSVImporter.preview(data: data, options: options, db: imported)
        XCTAssertFalse(repeated.canCommit); XCTAssertTrue(repeated.added.isEmpty)
        let reformatted = Data((String(decoding: data, as: UTF8.self) + "\n").utf8)
        let probable = try CSVImporter.preview(data: reformatted, options: options, db: imported)
        XCTAssertTrue(probable.canCommit); XCTAssertEqual(probable.probable, [1]); XCTAssertTrue(probable.added.isEmpty)
        XCTAssertEqual(imported, before)
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: imported).amount(.principal), 298_900_000)
    }
    func testDepositViolationsRequireExplicitConfirmationAndMarkForecastIncomplete() throws {
        var (db, contract, cash) = try fixture(.deposit, principal: 10_000_000)
        contract.terms[0].deposit.allowTopUp = false; try FinancialLedger.saveContract(contract, in: &db)
        var transfer = try Operation(kind: .transfer, date: day("2024-01-15"), accountID: cash.id, amount: 100_000); transfer.toAccountID = contract.accountID; transfer.toAmount = transfer.amount
        let before = db
        XCTAssertThrowsError(try Ledger.saveOperation(transfer, in: &db)); XCTAssertEqual(db, before)
        transfer.financial = FinanceOperationDetails(); transfer.financial?.contractViolationConfirmed = true; transfer.financial?.consequenceUnknown = true
        try Ledger.saveOperation(transfer, in: &db)
        XCTAssertEqual(try db.balance(contract.accountID), 10_100_000)
        let row = try XCTUnwrap(FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-20")).first { $0.kind == .depositInterest })
        XCTAssertEqual(row.accuracy, .incomplete)
        contract.terms[0].deposit.allowWithdrawal = false; try FinancialLedger.saveContract(contract, in: &db)
        var expense = Operation(kind: .expense, date: try day("2024-01-20"), accountID: contract.accountID, amount: 100_000)
        expense.categoryID = db.categories.first { $0.kind == .expense }!.id
        XCTAssertThrowsError(try Ledger.saveOperation(expense, in: &db))
        expense.financial = FinanceOperationDetails(); expense.financial?.contractViolationConfirmed = true; expense.financial?.consequenceUnknown = true
        try Ledger.saveOperation(expense, in: &db)
        XCTAssertEqual(try db.balance(contract.accountID), 10_000_000)
    }
    func testCreditCutoffUsesBankTimeAndUnknownTimeDoesNotProveGrace() throws {
        var (db, contract, cash) = try fixture(.revolvingCredit, principal: 3_000_000, end: nil)
        contract.cutoffHour = 17; contract.timeZoneID = "America/New_York"; try FinancialLedger.saveContract(contract, in: &db)
        var book = db.financeData; book.statements = [try CreditStatement(contractID: contract.id, start: day("2024-01-01"), closedOn: day("2024-01-31"), dueOn: day("2024-02-20"), balance: 3_000_000, minimum: 150_000, graceAmount: 3_000_000)]; db.finances = book
        let original = db
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 3_000_000, date: day("2024-02-20"), in: &db)
        let unknown = try XCTUnwrap(FinancialEngine.events(contract: contract, db: db, asOf: day("2024-02-21")).first { $0.kind == .gracePayment })
        XCTAssertNil(unknown.remaining); XCTAssertFalse(unknown.isFulfilled); XCTAssertEqual(unknown.accuracy, .incomplete)
        XCTAssertNil(try FinancialEngine.creditCost(contract: contract, db: db, paymentDate: day("2024-02-22"), asOf: day("2024-02-21")).total)
        db = original
        let early = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-02-20T21:59:00Z"))
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 3_000_000, date: day("2024-02-20"), creditedAt: early, in: &db)
        let confirmed = try XCTUnwrap(FinancialEngine.events(contract: contract, db: db, asOf: day("2024-02-21")).first { $0.kind == .gracePayment })
        XCTAssertEqual(confirmed.accuracy, .calculated); XCTAssertFalse(confirmed.notes.contains { $0.contains("нарушен") })
        db = original
        let late = early.addingTimeInterval(120)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 3_000_000, date: day("2024-02-20"), creditedAt: late, in: &db)
        XCTAssertTrue(try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-02-21")).first { $0.kind == .gracePayment }!.notes.contains { $0.contains("нарушен") })
    }
    func testImageAndFinancialBookSurviveEncryptedPortableBackup() throws {
        var (db, contract, cash) = try fixture(.mortgage, principal: 300_000_000)
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage()), bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bank = UserBank(name: "Локальный банк", country: .us, logo: bytes as Data); try FinancialLedger.saveBank(bank, in: &db)
        db.accounts[0].bankID = bank.id
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 3_000_000, interestCharge: 2_000_000, date: day("2024-02-01"), in: &db)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultStore(url: root.appendingPathComponent("source.beesave")); defer { store.close() }
        let key = try VaultCrypto.random(), recovery = try VaultCrypto.random()
        let bootstrap = Bootstrap(databaseID: db.id, password: nil, recovery: try VaultCrypto.seal(key, key: recovery, context: VaultCrypto.recoveryContext))
        try store.initialize(db: db, dataKey: key, bootstrap: bootstrap)
        let copy = root.appendingPathComponent("portable.mubak"); try store.backup(to: copy)
        let other = VaultStore(url: root.appendingPathComponent("other.beesave")); defer { other.close() }
        let restored = try other.previewRestore(from: copy, recovery: VaultCrypto.recoveryString(recovery))
        try other.restore(database: restored.0, dataKey: restored.2, bootstrap: restored.1.bootstrap, safetyCopy: nil)
        XCTAssertEqual(other.db, db); XCTAssertEqual(other.db?.financeData.banks.first?.logo, db.financeData.banks.first?.logo)
        XCTAssertEqual(try FinancialEngine.events(db: db, asOf: day("2024-02-02")), try FinancialEngine.events(db: other.db!, asOf: day("2024-02-02")))
        XCTAssertNil(try Data(contentsOf: copy).range(of: Data(bank.name.utf8)))
    }
    func testReminderUsesLondonDSTAndSnoozeKeepsStableIdentity() throws {
        var (db, contract, _) = try fixture(.deposit, principal: 10_000_000, start: "2024-03-01", end: "2024-05-01")
        contract.timeZoneID = "Europe/London"; contract.reminders.paymentOffsets = [0]; contract.reminders.interestEnabled = true; contract.reminders.hour = 9; try FinancialLedger.saveContract(contract, in: &db)
        var book = db.financeData; book.reminders.systemEnabled = true; db.finances = book
        let events = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-03-01")), now = try day("2024-03-01").date
        let first = try XCTUnwrap(FinancialReminderPlanner.plan(db: db, events: events, now: now).first { $0.eventToken == events.first { $0.kind == .depositInterest }?.id })
        XCTAssertEqual(first.fireAt, try day("2024-04-01").date.addingTimeInterval(8 * 3600))
        book.reminders.eventSnoozedUntil = [first.eventToken: first.fireAt.addingTimeInterval(86400)]; db.finances = book
        let postponed = try XCTUnwrap(FinancialReminderPlanner.plan(db: db, events: events, now: now).first { $0.eventToken == first.eventToken })
        XCTAssertEqual(first.id, postponed.id); XCTAssertEqual(postponed.fireAt, first.fireAt.addingTimeInterval(86400))
        XCTAssertTrue(try FinancialReminderPlanner.plan(db: db, events: events, now: now, delivered: [first.id]).contains { $0.id == first.id })
    }
    func testPartialLotRepaymentDoesNotDeductFulfillmentTwice() throws {
        var (db, contract, cash) = try fixture(.revolvingCredit, principal: 0, end: nil)
        contract.terms[0].credit.grace = .transactionDays; contract.terms[0].credit.graceDays = 55; try FinancialLedger.saveContract(contract, in: &db)
        let purchase = try Operation(kind: .expense, date: day("2024-01-02"), accountID: contract.accountID, amount: 100_000); try Ledger.saveOperation(purchase, in: &db)
        let event = try XCTUnwrap(FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-03")).first { $0.kind == .gracePayment })
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 40_000, allocations: [FinancialAllocation(.principal, 40_000, lotID: purchase.id)], eventID: event.id, date: day("2024-01-03"), in: &db)
        let refreshed = try XCTUnwrap(FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-04")).first { $0.kind == .gracePayment })
        XCTAssertEqual(refreshed.id, event.id); XCTAssertEqual(refreshed.remaining, 60_000); XCTAssertFalse(refreshed.isFulfilled)
    }
    func testOverlappingStatementsCannotReuseTheSamePaymentAsFullFulfillment() throws {
        var (db, contract, cash) = try fixture(.revolvingCredit, principal: 6_000_000, end: nil)
        db.financeData.statements = [
            try CreditStatement(contractID: contract.id, start: day("2024-01-01"), closedOn: day("2024-01-31"), dueOn: day("2024-02-20"), balance: 3_000_000, minimum: 150_000, graceAmount: 3_000_000),
            try CreditStatement(contractID: contract.id, start: day("2024-02-01"), closedOn: day("2024-02-29"), dueOn: day("2024-03-20"), balance: 3_000_000, minimum: 150_000, graceAmount: 3_000_000)
        ]
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 3_000_000, date: day("2024-03-01"), in: &db)
        let rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-03-02"))
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { !$0.isFulfilled && $0.remaining == nil && $0.accuracy == .incomplete })
        XCTAssertEqual(try FinancialLedger.debt(accountID: contract.accountID, db: db).debt, 3_000_000)
    }
    func testDifferentiatedAndFloatingIndexUnknownSchedule() throws {
        var (db, contract, _) = try fixture(.mortgage, principal: 12_000_000)
        contract.terms[0].loan.method = .differentiated; try FinancialLedger.saveContract(contract, in: &db)
        let rows = try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01")).filter { $0.kind == .loanPayment }
        XCTAssertEqual(rows.first?.amount, 1_120_000); XCTAssertEqual(rows[1].amount, 1_110_000); XCTAssertEqual(rows.last?.amount, 1_010_000); XCTAssertEqual(rows.last?.balanceAfter, 0)
        contract.terms[0].indexName = "SONIA"; contract.terms[0].marginPercent = "2"; contract.terms[0].indexPercent = nil; try FinancialLedger.saveContract(contract, in: &db)
        XCTAssertTrue(try FinancialEngine.events(contract: contract, db: db, asOf: day("2024-01-01")).allSatisfy { $0.amount == nil && $0.accuracy == .incomplete })
        contract.terms[0].indexPercent = "10"; contract.terms[0].capPercent = "8"; contract.terms[0].floorPercent = "3"; try FinancialLedger.saveContract(contract, in: &db)
        XCTAssertEqual(try contract.terms[0].rate(), Decimal(string: "0.08"))
    }
    func testAutomaticRepaymentCSVPreservesLotAllocationWithoutFutureTerms() throws {
        var (db, contract, cash) = try fixture(.revolvingCredit, principal: 0, end: nil)
        contract.terms[0].credit.repaymentOrder = .highestRate; contract.terms[0].credit.buckets[0].annualPercent = "12"; contract.terms[0].credit.buckets[1].annualPercent = "48"; try FinancialLedger.saveContract(contract, in: &db)
        var first = try Operation(kind: .expense, date: day("2024-01-02"), accountID: contract.accountID, amount: 100_000); first.financial = FinanceOperationDetails(); try Ledger.saveOperation(first, in: &db)
        var second = try Operation(kind: .expense, date: day("2024-01-03"), accountID: contract.accountID, amount: 100_000); second.financial = FinanceOperationDetails(); second.financial?.transactionKind = .cash; try Ledger.saveOperation(second, in: &db)
        try FinancialLedger.payDebt(contractID: contract.id, from: cash.id, amount: 150_000, date: day("2024-01-04"), in: &db)
        XCTAssertEqual(db.operations.last?.financial?.allocations.first { $0.lotID == second.id }?.amount, 100_000)
        let data = try CSVCodec.export(db.operations, db: db); var options = ImportOptions(); options.createReferences = true
        let imported = try CSVImporter.preview(data: data, options: options, db: Database())
        XCTAssertTrue(imported.canCommit, imported.issues.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(try FinancialLedger.creditLots(accountID: contract.accountID, db: db), try FinancialLedger.creditLots(accountID: contract.accountID, db: imported.database))
        let repeated = try CSVImporter.preview(data: data, options: options, db: db)
        XCTAssertTrue(repeated.canCommit); XCTAssertTrue(repeated.added.isEmpty)
    }
    func testUnknownDebtCompositionAndTaxAreDistinctFromMissingFX() throws {
        var (db, contract, _) = try fixture(.mortgage, principal: 10_000_000)
        _ = try Ledger.reconcile(accountID: contract.accountID, observed: -12_000_000, reason: "Сверка", in: &db)
        var report = Report(name: "Тело"); report.dataset = .debt; report.metric = .principal; report.grouping = .account
        let value = try Reports.total(FinancialReports.rows(report, db: db, asOf: .today))
        XCTAssertEqual(value.known, 10_000_000); XCTAssertTrue(value.partial); XCTAssertTrue(value.missing.isEmpty); XCTAssertFalse(value.missingConditions.isEmpty)
        (db, contract, _) = try fixture(.deposit, principal: 10_000_000)
        report.dataset = .depositYield; report.metric = .netYield; report.filters = Filters(start: try day("2024-01-01"), end: try day("2025-01-01"))
        let unknownTax = try Reports.total(FinancialReports.rows(report, db: db, asOf: day("2024-01-01")))
        XCTAssertTrue(unknownTax.partial); XCTAssertTrue(unknownTax.missing.isEmpty); XCTAssertFalse(unknownTax.missingConditions.isEmpty)
    }

}
