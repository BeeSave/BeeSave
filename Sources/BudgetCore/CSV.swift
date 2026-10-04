import Foundation

public struct CSVRecord: Sendable { public var fields: [String]; public var line: Int; public var number: Int }
public enum CSVCodec {
    public static func decode(_ data: Data, encoding: String) throws -> String {
        guard data.count <= 104_857_600 else { throw BudgetError.invalid("CSV превышает 100 MiB.") }
        guard let s = String(data: data, encoding: encoding == "Windows-1251" ? .windowsCP1251 : .utf8) else { throw BudgetError.invalid("Файл не читается в выбранной кодировке. Выберите UTF-8 или Windows-1251.") }; return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
    }
    public static func parse(_ text: String, separator: UInt8 = 44) throws -> [CSVRecord] {
        var rows: [CSVRecord] = []; var fields: [String] = []; var field: [UInt8] = []; var quoted = false; var ended = false; var line = 1; var startLine = 1; var lastWasCR = false
        func finishField() { fields.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true); ended = false }
        func finishRow() throws { finishField(); if fields.count > 1 || fields[0] != "" { rows.append(CSVRecord(fields: fields, line: startLine, number: rows.count + 1)) }; fields.removeAll(keepingCapacity: true); guard rows.count <= 100_001 else { throw BudgetError.invalid("CSV превышает 100 000 операций.") } }
        for byte in text.utf8 {
            if quoted {
                if byte == 34 { quoted = false; ended = true } else { field.append(byte); if byte == 10 { line += 1 } }; continue
            }
            if ended && byte == 34 { field.append(34); quoted = true; ended = false; continue }
            if byte == separator { finishField(); lastWasCR = false; continue }
            if byte == 10 || byte == 13 {
                if byte == 10 && lastWasCR { lastWasCR = false; startLine = line; continue }
                try finishRow(); line += 1; startLine = line; lastWasCR = byte == 13; continue
            }
            lastWasCR = false
            if byte == 34 { guard field.isEmpty && !ended else { throw BudgetError.invalid("Кавычка внутри незаключённого поля, строка \(line).") }; quoted = true }
            else { guard !ended else { throw BudgetError.invalid("После закрывающей кавычки ожидается разделитель, строка \(line).") }; field.append(byte) }
        }
        guard !quoted else { throw BudgetError.invalid("Незакрытые кавычки, строка \(startLine).") }
        if !field.isEmpty || !fields.isEmpty || ended { try finishRow() }; return rows
    }
    public static func guessSeparator(_ text: String) -> UInt8 { [UInt8(44), 59, 9].max { a, b in (try? parse(text, separator: a).first?.fields.count) ?? 0 < (try? parse(text, separator: b).first?.fields.count) ?? 0 } ?? 44 }
    public static func quote(_ text: String) -> String { if text.contains(",") || text.contains("\"") || text.contains("\n") || text.contains("\r") { return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }; return text }
    public static func protect(_ text: String) -> String {
        if text.hasPrefix("'") { return "'" + text }
        if let c = text.unicodeScalars.first, "=+-@".unicodeScalars.contains(c) || c.value < 32 || c.value == 127 { return "'" + text }; return text
    }
    public static func unprotect(_ text: String) -> String { guard text.hasPrefix("'") else { return text }; let rest = String(text.dropFirst()); if rest.hasPrefix("'") { return rest }; if let c = rest.unicodeScalars.first, "=+-@".unicodeScalars.contains(c) || c.value < 32 || c.value == 127 { return rest }; return text }
    public static let headers = "schema_version operation_id type date account_id account_name currency amount to_account_id to_account_name to_currency to_amount category_type category_path project_name budget_mode comment transfer_rate fx_snapshot account_opened_on to_account_opened_on".split(separator: " ").map(String.init)
    public static func export(_ operations: [Operation], db: Database) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; var lines = [headers.joined(separator: ",")]
        let accounts = Dictionary(uniqueKeysWithValues: db.accounts.map { ($0.id, $0) }); let projects = Dictionary(uniqueKeysWithValues: db.projects.map { ($0.id, $0) })
        for o in operations {
            guard let a = accounts[o.accountID] else { throw BudgetError.corrupt }; let to = o.toAccountID.flatMap { accounts[$0] }; let fx = String(decoding: try encoder.encode(o.fx), as: UTF8.self)
            let values = ["1", o.id.uuidString, o.kind.rawValue, o.date.rawValue, a.id.uuidString, protect(a.name), a.currency, Money.string(o.amount, currency: a.currency), to?.id.uuidString ?? "", protect(to?.name ?? ""), to?.currency ?? "", o.toAmount.map { Money.string($0, currency: to?.currency ?? a.currency) } ?? "", o.kind.isFlow ? o.kind.rawValue : "", protect(o.kind.isFlow ? db.categoryPath(o.categoryID) : ""), protect(o.projectID.flatMap { projects[$0]?.name } ?? ""), o.budgetMode.rawValue, protect(o.comment), o.transferRate ?? "", fx, a.openedOn.rawValue, to?.openedOn.rawValue ?? ""]
            lines.append(values.map(quote).joined(separator: ","))
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
public struct ImportOptions: Sendable {
    public var encoding = "UTF-8"; public var separator: UInt8 = 44; public var dateFormat = "ISO"; public var decimalSeparator = "."; public var signRule = "type"; public var columns: [String: String] = [:]
    public var createReferences = false; public var importProbableDuplicates = false; public var excludedRows: Set<Int> = []; public var accountMapping: [String: UUID] = [:]; public var categoryMapping: [String: UUID] = [:]; public var projectMapping: [String: UUID] = [:]; public var newCurrencies: [String: String] = [:]; public var newOpenedOn: [String: Day] = [:]; public var earlierOpening: [UUID: Day] = [:]
    public init() {}
}
public struct ImportIssue: Identifiable, Sendable { public var id: Int { row }; public var row: Int; public var line: Int; public var field: String; public var message: String }
public struct ImportPreview: Sendable {
    public var sourceRevision: UInt64
    public var database: Database; public var issues: [ImportIssue]; public var added: [UUID]; public var skipped: Int; public var excluded: Int; public var probable: [Int]; public var newAccounts: [Account]; public var newCategories: [Category]; public var newProjects: [Project]; public var totals: [String: Int64]; public var missingRates: Int; public var fingerprint: String
    public var canCommit: Bool { issues.isEmpty }
}
public enum CSVImporter {
    public static func commit(_ preview: ImportPreview, into db: inout Database) throws {
        guard preview.canCommit else { throw BudgetError.invalid("Исправьте или явно исключите ошибочные строки.") }
        guard db.id == preview.database.id, (db.revision ?? 0) == preview.sourceRevision else { throw BudgetError.conflict("Данные изменились после предпросмотра. Обновите проверку перед импортом.") }
        db = preview.database
        db.imports.append(ImportBatch(fingerprint: preview.fingerprint, added: preview.added, skipped: preview.skipped, excluded: preview.excluded))
    }
    static func signature(_ o: Operation) -> String { "\(o.date)|\(o.kind.rawValue)|\(o.accountID)|\(o.amount)|\(o.toAccountID?.uuidString ?? "")|\(o.toAmount ?? 0)|\(o.categoryID?.uuidString ?? "")|\(o.projectID?.uuidString ?? "")|\(o.comment)" }
    static func same(_ a: Operation, _ b: Operation) -> Bool { signature(a) == signature(b) && a.budgetMode == b.budgetMode && a.transferRate == b.transferRate && a.fx == b.fx }
    public static func preview(data: Data, options: ImportOptions, db: Database, cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> ImportPreview {
        let rows = try CSVCodec.parse(CSVCodec.decode(data, encoding: options.encoding), separator: options.separator)
        let today = Day.today
        guard let header = rows.first else { throw BudgetError.invalid("CSV пуст.") }
        guard Set(header.fields).count == header.fields.count else { throw BudgetError.invalid("Повторяющиеся заголовки CSV. Исправьте файл.") }
        let canonical = header.fields.contains("schema_version") && header.fields.contains("operation_id")
        var work = db; let originalAccounts = Set(db.accounts.map(\.id)); let originalCats = Set(db.categories.map(\.id)); let originalProjects = Set(db.projects.map(\.id))
        var index = Dictionary(uniqueKeysWithValues: header.fields.enumerated().map { ($0.element, $0.offset) }); if !canonical { for (field, column) in options.columns { if let i = index[column] { index[field] = i } } }
        var existing = Dictionary(uniqueKeysWithValues: db.operations.map { ($0.id, $0) }); var fingerprints = Set(db.operations.map(signature)); var accountNames = Dictionary(uniqueKeysWithValues: work.accounts.map { (Ledger.normalized($0.name), $0.id) })
        for (id, day) in options.earlierOpening { if let i = work.accounts.firstIndex(where: { $0.id == id }) { work.accounts[i].openedOn = day } }
        var issues: [ImportIssue] = []; var added: [UUID] = []; var skipped = 0; var excluded = 0; var probable: [Int] = []; var totals: [String: Int64] = [:]; var missing = 0
        for (offset, record) in rows.dropFirst().enumerated() {
            if cancelled() { throw CancellationError() }; if offset % 100 == 0 { progress(Double(offset) / Double(max(1, rows.count - 1))) }
            let row = record.number - 1; if options.excludedRows.contains(row) { excluded += 1; continue }
            func field(_ name: String) -> String { guard let i = index[name], i < record.fields.count else { return "" }; return record.fields[i] }
            func text(_ name: String) -> String { canonical ? CSVCodec.unprotect(field(name)) : field(name) }
            var currentField = "формат записи"
            do {
                guard record.fields.count == header.fields.count else { throw BudgetError.invalid("Число полей не совпадает с заголовком.") }
                if canonical { guard field("schema_version") == "1" else { throw BudgetError.newerVersion } }
                currentField = "date"; let date: Day
                if canonical || options.dateFormat == "ISO" { date = try Day(field("date")) }
                else { let p = field("date").split(whereSeparator: { "/.-".contains($0) }); guard p.count == 3, let first = Int(p[0]), let second = Int(p[1]), let year = Int(p[2]), p[2].count == 4 else { throw BudgetError.invalid("Дата не соответствует выбранному формату.") }; date = try Day(String(format: "%04d-%02d-%02d", year, options.dateFormat == "DMY" ? second : first, options.dateFormat == "DMY" ? first : second)) }
                currentField = "type / amount"; let kind: OperationKind
                var rawAmount = field("amount")
                if !canonical && options.signRule == "separate" {
                    let income = field("income"); let expense = field("expense"); let iv = income.isEmpty ? Decimal(0) : try Money.decimal(income.replacingOccurrences(of: options.decimalSeparator, with: ".")); let ev = expense.isEmpty ? Decimal(0) : try Money.decimal(expense.replacingOccurrences(of: options.decimalSeparator, with: ".")); guard iv == 0 || ev == 0 else { throw BudgetError.invalid("Одновременно заполнены доход и расход.") }
                    let hasIncome = iv != 0; kind = hasIncome ? .income : .expense; rawAmount = hasIncome ? income : expense
                } else if !canonical && options.signRule == "signed" { kind = rawAmount.hasPrefix("-") ? .expense : .income; if rawAmount.hasPrefix("-") { rawAmount.removeFirst() } }
                else { let value = field("type").lowercased(); guard let k = OperationKind(rawValue: value) ?? ["расход": .expense, "доход": .income][value] else { throw BudgetError.invalid("Тип должен быть income/expense или выбранное правило знака.") }; kind = k }
                if !canonical && !kind.isFlow { throw BudgetError.invalid("Переводы/сверки/начальные остатки импортируются только в формате BeeSave.") }
                func account(prefix: String) throws -> Account {
                    let name = text(prefix + "account_name").isEmpty && prefix.isEmpty ? text("account") : text(prefix + "account_name"); try Ledger.nonempty(name)
                    let csvCurrency = field(prefix + "currency")
                    let id = options.accountMapping[name] ?? accountNames[Ledger.normalized(name)]
                    if let id { let a = try work.account(id); guard csvCurrency.isEmpty || a.currency == csvCurrency else { throw BudgetError.invalid("Валюта \(name) не совпадает с CSV.") }; guard !a.archived else { throw BudgetError.invalid("Счёт \(name) архивирован.") }; return a }
                    guard options.createReferences else { throw BudgetError.invalid("Неизвестный счёт «\(name)»: сопоставьте или разрешите создание.") }
                    let currency = options.newCurrencies[name] ?? (canonical ? csvCurrency : ""); _ = try Currency.get(currency)
                    let opened = try options.newOpenedOn[name] ?? (canonical ? Day(field(prefix + "account_opened_on")) : nil)
                    guard let opened else { throw BudgetError.invalid("Выберите дату открытия нового счёта «\(name)».") }
                    var a = Account(name: name, currency: currency, openedOn: opened)
                    if canonical, let id = UUID(uuidString: field(prefix + "account_id")) { a.id = id; guard !work.accounts.contains(where: { $0.id == id }) else { throw BudgetError.conflict("UUID счёта относится к другому имени. Сопоставьте счёт явно.") } }
                    try Ledger.saveAccount(a, in: &work); accountNames[Ledger.normalized(name)] = a.id; return a
                }
                currentField = "account / currency / account_opened_on"; let a = try account(prefix: "")
                currentField = "amount"; let amount = try Money.parse(rawAmount.replacingOccurrences(of: options.decimalSeparator, with: "."), currency: a.currency)
                var o = Operation(kind: kind, date: date, accountID: a.id, amount: amount)
                currentField = "operation_id"; if canonical { guard let id = UUID(uuidString: field("operation_id")) else { throw BudgetError.invalid("Невалидный UUID операции.") }; o.id = id }
                currentField = "to_account / to_amount / transfer_rate"
                if kind == .transfer { let b = try account(prefix: "to_"); o.toAccountID = b.id; o.toAmount = try Money.parse(field("to_amount"), currency: b.currency); o.transferRate = try Money.ratio(from: o.amount, currency: a.currency, to: o.toAmount!, toCurrency: b.currency); guard try field("transfer_rate").isEmpty || Money.decimal(field("transfer_rate")) == Money.decimal(o.transferRate!) else { throw BudgetError.invalid("Курс перевода не соответствует суммам.") } }
                o.comment = text("comment")
                currentField = "budget_mode"
                if canonical { guard let mode = BudgetMode(rawValue: field("budget_mode")) else { throw BudgetError.invalid("Режим бюджета должен быть automatic или excluded.") }; o.budgetMode = mode }
                else { o.budgetMode = .automatic }
                currentField = "category_type"
                if canonical { guard kind.isFlow ? field("category_type") == kind.rawValue : field("category_type").isEmpty else { throw BudgetError.invalid("Тип категории не соответствует типу операции.") } }
                currentField = "category_path"; if kind.isFlow {
                    let path = text("category_path").isEmpty ? text("category") : text("category_path")
                    if path.isEmpty { o.categoryID = work.categories.first { $0.kind == kind && $0.system }?.id }
                    else if let id = options.categoryMapping[path] { o.categoryID = id }
                    else {
                        let parts = path.components(separatedBy: " / "); guard parts.count <= 2 else { throw BudgetError.invalid("Категория имеет больше двух уровней.") }; var parent: UUID?
                        for part in parts {
                            if let c = work.categories.first(where: { $0.kind == kind && $0.parentID == parent && Ledger.normalized($0.name) == Ledger.normalized(part) }) { guard !c.archived else { throw BudgetError.invalid("Категория архивирована.") }; parent = c.id }
                            else { guard options.createReferences else { throw BudgetError.invalid("Неизвестная категория «\(path)». Сопоставьте или разрешите создание.") }; let c = Category(name: part, kind: kind, parentID: parent); try Ledger.saveCategory(c, in: &work); parent = c.id }
                        }
                        o.categoryID = parent
                    }
                    currentField = "project_name"; let projectName = text("project_name").isEmpty ? text("project") : text("project_name")
                    if !projectName.isEmpty {
                        if let id = options.projectMapping[projectName] { o.projectID = id }
                        else if let p = work.projects.first(where: { Ledger.normalized($0.name) == Ledger.normalized(projectName) }) { guard !p.archived else { throw BudgetError.invalid("Проект архивирован.") }; o.projectID = p.id }
                        else { guard options.createReferences else { throw BudgetError.invalid("Неизвестный проект «\(projectName)». Сопоставьте или разрешите создание.") }; let p = Project(name: projectName); try Ledger.saveProject(p, in: &work); o.projectID = p.id }
                    }
                }
                currentField = "fx_snapshot"; if canonical && !field("fx_snapshot").isEmpty { o.fx = try JSONDecoder().decode([FXRate].self, from: Data(field("fx_snapshot").utf8)) }
                currentField = "учётные ограничения"
                try Ledger.validateOperation(o, accounts: Dictionary(uniqueKeysWithValues: work.accounts.map { ($0.id, $0) }), categories: Dictionary(uniqueKeysWithValues: work.categories.map { ($0.id, $0) }), projects: Set(work.projects.map(\.id)), today: today)
                currentField = "operation_id"; if let old = existing[o.id] { guard same(old, o) else { throw BudgetError.conflict("Конфликт UUID: содержимое отличается. Автоматическая перезапись запрещена.") }; skipped += 1; continue }
                let fingerprint = signature(o)
                if !canonical && fingerprints.contains(fingerprint) { probable.append(row); if !options.importProbableDuplicates { skipped += 1; continue } }
                existing[o.id] = o; fingerprints.insert(fingerprint); work.operations.append(o); added.append(o.id)
                let signed = kind == .expense || kind == .transfer ? -amount : amount; totals[a.currency + " · " + kind.title] = try Money.add(totals[a.currency + " · " + kind.title] ?? 0, signed)
                if kind.isFlow && a.currency != work.settings.baseCurrency, try Reports.rate(from: a.currency, to: work.settings.baseCurrency, rates: o.fx, on: o.date) == nil { missing += 1 }
            } catch { issues.append(ImportIssue(row: row, line: record.line, field: currentField, message: error.localizedDescription)) }
        }
        // Invalid rows may have created provisional references; none can enter the live database until all errors are resolved.
        if issues.isEmpty { try Ledger.validate(work) }; progress(1)
        return ImportPreview(sourceRevision: db.revision ?? 0, database: work, issues: issues, added: added, skipped: skipped, excluded: excluded, probable: probable, newAccounts: work.accounts.filter { !originalAccounts.contains($0.id) }, newCategories: work.categories.filter { !originalCats.contains($0.id) }, newProjects: work.projects.filter { !originalProjects.contains($0.id) }, totals: totals, missingRates: missing, fingerprint: VaultCrypto.fingerprint(data))
    }
}
