import XCTest
@testable import BudgetCore

final class CSVTests: XCTestCase {
    func testStalePreviewCannotOverwriteNewOperation() throws {
        var db = Database(); let a = Account(name: "Банк", currency: "RUB"); try Ledger.saveAccount(a, in: &db)
        let csv = Data("date,type,account_name,amount\n\(Day.today),expense,Банк,1\n".utf8)
        let p = try CSVImporter.preview(data: csv, options: ImportOptions(), db: db)
        try Ledger.saveOperation(Operation(kind: .income, accountID: a.id, amount: 500), in: &db); db.revision = 1
        let before = db; XCTAssertThrowsError(try CSVImporter.commit(p, into: &db)); XCTAssertEqual(db, before)
        let refreshed = try CSVImporter.preview(data: csv, options: ImportOptions(), db: db); try CSVImporter.commit(refreshed, into: &db)
        XCTAssertEqual(db.operations.count, 2); XCTAssertEqual(db.imports.count, 1)
    }
    func testAC20EncodingSeparatorsQuotesLines() throws {
        let text = "Дата;Комментарий\r\n03/10/2026;\"Привет; \"\"мир\"\"\nвторая строка\"\r\n"
        let encoded = try XCTUnwrap(text.data(using: .windowsCP1251)); let decoded = try CSVCodec.decode(encoded, encoding: "Windows-1251"); let rows = try CSVCodec.parse(decoded, separator: 59)
        XCTAssertEqual(rows.count, 2); XCTAssertEqual(rows[1].fields[1], "Привет; \"мир\"\nвторая строка"); XCTAssertEqual(rows[1].line, 2)
        XCTAssertEqual(try CSVCodec.parse("a\tb\n1\t2", separator: 9)[1].fields, ["1", "2"]); XCTAssertEqual(try CSVCodec.decode(Data([0xef, 0xbb, 0xbf]) + Data("a,b".utf8), encoding: "UTF-8"), "a,b")
        XCTAssertThrowsError(try CSVCodec.parse("a,b\n\"unclosed,b"))
    }
    func fixture() throws -> Database {
        var db = Database(); let a = Account(name: "=Формула", currency: "RUB", openedOn: .today.adding(-20)); let b = Account(name: "'USD", currency: "USD", openedOn: a.openedOn)
        try Ledger.saveAccount(a, opening: 100_000, in: &db); try Ledger.saveAccount(b, in: &db)
        var expense = Operation(kind: .expense, accountID: a.id, amount: 200); expense.comment = "=SUM(A1)\n\"цитата\""; try Ledger.saveOperation(expense, in: &db)
        var income = Operation(kind: .income, accountID: b.id, amount: 1_000); income.comment = "'апостроф"; income.fx = [FXRate(base: "USD", quote: "RUB", rate: "90", date: .today)]; try Ledger.saveOperation(income, in: &db)
        var transfer = Operation(kind: .transfer, accountID: a.id, amount: 9_000); transfer.toAccountID = b.id; transfer.toAmount = 100; try Ledger.saveOperation(transfer, in: &db)
        _ = try Ledger.reconcile(accountID: a.id, observed: 90_750, reason: "-Сверка\nперенос", in: &db)
        return db
    }
    func testAC22FullRoundTripAndFormulaProtection() throws {
        let original = try fixture(); let csv = try CSVCodec.export(original.operations, db: original); XCTAssertTrue(String(decoding: csv, as: UTF8.self).contains("'=Формула"))
        var options = ImportOptions(); options.createReferences = true; let p = try CSVImporter.preview(data: csv, options: options, db: Database())
        XCTAssertTrue(p.issues.isEmpty, p.issues.map(\.message).joined(separator: "\n")); XCTAssertEqual(p.added.count, 5)
        for a in original.accounts { XCTAssertEqual(try p.database.balance(a.id), try original.balance(a.id)) }
        for o in original.operations { let copy = try XCTUnwrap(p.database.operations.first { $0.id == o.id }); XCTAssertEqual(copy.comment, o.comment); XCTAssertEqual(copy.fx, o.fx); XCTAssertEqual(copy.amount, o.amount); XCTAssertEqual(copy.toAmount, o.toAmount); XCTAssertEqual(copy.transferRate, o.transferRate); XCTAssertEqual(copy.date, o.date) }
        let duplicate = try CSVImporter.preview(data: csv, options: options, db: p.database); XCTAssertEqual(duplicate.skipped, 5); XCTAssertTrue(duplicate.added.isEmpty)
        for text in ["=SUM(A1)", "+hello", "-hello", "@hello", "\tfoo", "'foo", "''foo", "hello"] { XCTAssertEqual(CSVCodec.unprotect(CSVCodec.protect(text)), text) }
    }
    func testUUIDConflictAndExternalDuplicates() throws {
        let db = try fixture(); var changed = db.operations; changed[1].amount = 300; let csv = try CSVCodec.export(changed, db: db); var o = ImportOptions(); o.createReferences = true; let p = try CSVImporter.preview(data: csv, options: o, db: db); XCTAssertFalse(p.canCommit); XCTAssertTrue(p.issues.contains { $0.message.contains("UUID") })
        let csv2 = Data("date,type,account_name,currency,amount,comment\n\(Day.today),expense,'USD,USD,10,purchase\n\(Day.today),expense,'USD,USD,10,purchase\n".utf8)
        o.createReferences = false; let skipped = try CSVImporter.preview(data: csv2, options: o, db: db); XCTAssertEqual(skipped.added.count, 1); XCTAssertEqual(skipped.skipped, 1); o.importProbableDuplicates = true; XCTAssertEqual(try CSVImporter.preview(data: csv2, options: o, db: db).added.count, 2)
    }
    func testDateExplicitCurrencyAndExcluded() throws {
        let db = try fixture(); let csv = Data("date,type,account_name,currency,amount\n03/04/2026,expense,=Формула,USD,1\n".utf8); var o = ImportOptions()
        var p = try CSVImporter.preview(data: csv, options: o, db: db); XCTAssertFalse(p.canCommit); o.dateFormat = "DMY"; p = try CSVImporter.preview(data: csv, options: o, db: db); XCTAssertFalse(p.canCommit); XCTAssertTrue(p.issues.first!.message.contains("Валюта")); o.excludedRows = [1]; XCTAssertTrue(try CSVImporter.preview(data: csv, options: o, db: db).canCommit)
    }
    func testAC21ThousandRowsAtomicFailureAndAC29RequiredBackup() throws {
        var db = Database(); let a = Account(name: "Банк", currency: "RUB"); try Ledger.saveAccount(a, in: &db)
        let csv = Data(("date,type,account_name,amount,comment\n" + (0..<1_000).map { "\(Day.today),expense,Банк,1,№\($0)\n" }.joined()).utf8)
        let p = try CSVImporter.preview(data: csv, options: ImportOptions(), db: db); XCTAssertTrue(p.canCommit); XCTAssertEqual(p.added.count, 1_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); let store = VaultStore(url: root.appendingPathComponent("data.beesave")); defer { store.close(); try? FileManager.default.removeItem(at: root) }
        let key = try VaultCrypto.random(); let recovery = try VaultCrypto.random(); let b = Bootstrap(databaseID: db.id, password: nil, recovery: try VaultCrypto.seal(key, key: recovery, context: VaultCrypto.recoveryContext)); try store.initialize(db: db, dataKey: key, bootstrap: b)
        store.beforeWrite = { throw BudgetError.storage("Injected") }; XCTAssertThrowsError(try store.transaction { $0 = p.database }); XCTAssertEqual(store.db, db); store.beforeWrite = nil; try store.transaction { $0 = p.database }; XCTAssertEqual(store.db?.operations.count, 1_000)
        let unusable = root.appendingPathComponent("file"); try Data("x".utf8).write(to: unusable); XCTAssertThrowsError(try Backups.beforeMassChange(store: store, folder: unusable)); XCTAssertEqual(store.db?.operations.count, 1_000)
        XCTAssertThrowsError(try CSVImporter.preview(data: csv, options: ImportOptions(), db: db, cancelled: { true }))
    }
}
