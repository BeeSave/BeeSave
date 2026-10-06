import SwiftUI
import UniformTypeIdentifiers
import BudgetCore
import BudgetPresentation

struct ImportView: View {
    @EnvironmentObject var model: AppModel; @Environment(\.dismiss) var dismiss
    @State private var data: Data?; @State private var filename = ""; @State private var options = ImportOptions(); @State private var headers: [String] = []; @State private var stage = 0; @State private var preview: ImportPreview?; @State private var error = ""; @State private var working = false; @State private var progress = 0.0; @State private var task: Task<Void, Never>?; @State private var accountNames: [String] = []; @State private var categoryNames: [String] = []; @State private var projectNames: [String] = []; @State private var discard = false; @State private var committed = false
    var canonical: Bool { headers.contains("schema_version") && headers.contains("operation_id") }
    @State private var previewRun = UUID()
    @State private var examples: [String: String] = [:]
    @State private var financialRow = "1"
    @State private var paymentRow: CSVPaymentRow?
    func firstOperations(_ p: ImportPreview) -> [BudgetCore.Operation] {
        let ids = Set(p.added)
        return Array(p.database.operations.lazy.filter { ids.contains($0.id) }.prefix(200))
    }
    let columns = ["date", "type", "account_name", "currency", "amount", "income", "expense", "category_path", "project_name", "comment"]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Импорт CSV").font(.title2.bold()); Text("\(stage + 1) / 5 · " + ["Выбор файла", "Формат и колонки", "Сопоставление", "Проверка и подтверждение", "Результат"][stage]).foregroundStyle(BeeStyle.muted)
            ScrollView { VStack(alignment: .leading, spacing: 12) {
                if stage == 0 { Text("До подтверждения база не изменяется. Исходный CSV не сохраняется в приложении или копиях."); Button("Выбрать CSV…", action: choose); Text(filename) }
                if stage == 1 {
                    Picker("Кодировка", selection: $options.encoding) { Text("UTF-8").tag("UTF-8"); Text("Windows-1251").tag("Windows-1251") }
                    Picker("Разделитель", selection: $options.separator) { Text("Запятая").tag(UInt8(44)); Text("Точка с запятой").tag(UInt8(59)); Text("Табуляция").tag(UInt8(9)) }
                    Button("Перечитать заголовки", action: readHeaders)
                    if canonical { Text("Обнаружен BeeSave CSV v1 / v2. Даты ISO, десятичная точка, UUID и курсовые снимки сохраняются.") }
                    else {
                        Picker("Формат даты (выберите явно)", selection: $options.dateFormat) { Text("YYYY-MM-DD").tag("ISO"); Text("DD/MM/YYYY").tag("DMY"); Text("MM/DD/YYYY").tag("MDY") }
                        Picker("Десятичный знак", selection: $options.decimalSeparator) { Text("Точка").tag("."); Text("Запятая").tag(",") }
                        Picker("Правило суммы", selection: $options.signRule) { Text("Положительная сумма и колонка типа").tag("type"); Text("Отрицательная — расход, положительная — доход").tag("signed"); Text("Отдельные доход и расход").tag("separate") }
                        Text("Сопоставление колонок").font(.headline)
                        ForEach(columns, id: \.self) { field in HStack { Text(columnTitle(field)).frame(width: 145, alignment: .leading); Picker(columnTitle(field), selection: Binding(get: { options.columns[field] ?? (headers.contains(field) ? field : "") }, set: { options.columns[field] = $0 })) { Text("Не используется").tag(""); ForEach(headers, id: \.self) { Text($0).tag($0) } }.labelsHidden(); Text(example(field)).font(.caption).foregroundStyle(BeeStyle.muted).frame(width: 180, alignment: .leading) } }
                    }
                }
                if stage == 2 {
                    Toggle("Разрешить создание неизвестных счетов, категорий и проектов", isOn: $options.createReferences)
                    Text("Новые счета начинают с нулевого остатка; начальные события переносятся только из BeeSave CSV. Для другого остатка создайте счёт заранее.").font(.caption).foregroundStyle(BeeStyle.muted)
                    Text("Счета · \(accountNames.count) · нерешённых: \(unresolvedAccounts)").font(.headline)
                    ForEach(accountNames, id: \.self) { name in GroupBox(name) { VStack(alignment: .leading) {
                        Picker("Сопоставить счёт", selection: Binding(get: { options.accountMapping[name] }, set: { options.accountMapping[name] = $0 })) { Text("По имени / создать").tag(nil as UUID?); ForEach(model.db?.accounts ?? []) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) } }
                        if !canonical && options.accountMapping[name] == nil && model.db?.accounts.contains(where: { Ledger.normalized($0.name) == Ledger.normalized(name) }) != true { CurrencyPicker(title: "Валюта нового счёта", selection: Binding(get: { options.newCurrencies[name] ?? "RUB" }, set: { options.newCurrencies[name] = $0 })); DayField(title: "Дата открытия нового счёта", value: Binding(get: { options.newOpenedOn[name]?.rawValue ?? Day.today.rawValue }, set: { options.newOpenedOn[name] = try? Day($0) })).onAppear { if options.newOpenedOn[name] == nil { options.newOpenedOn[name] = .today } } }
                        if let existing = options.accountMapping[name] ?? model.db?.accounts.first(where: { Ledger.normalized($0.name) == Ledger.normalized(name) })?.id { Toggle("Изменить дату открытия", isOn: Binding(get: { options.earlierOpening[existing] != nil }, set: { options.earlierOpening[existing] = $0 ? model.db?.accounts.first { $0.id == existing }?.openedOn : nil })).toggleStyle(.checkbox); if options.earlierOpening[existing] != nil { DayField(title: "Новая дата открытия", value: Binding(get: { options.earlierOpening[existing]?.rawValue ?? Day.today.rawValue }, set: { options.earlierOpening[existing] = try? Day($0) })) } }
                    } } }
                    DisclosureGroup("Категории · \(categoryNames.count) · нерешённых: \(unresolvedCategories)") { ForEach(categoryNames, id: \.self) { name in Picker("Категория: " + name, selection: Binding(get: { options.categoryMapping[name] }, set: { options.categoryMapping[name] = $0 })) { Text("По пути / создать").tag(nil as UUID?); ForEach(model.db?.categories ?? []) { Text(model.db?.categoryPath($0.id) ?? $0.name).tag(Optional($0.id)) } } }
                    }
                    DisclosureGroup("Проекты · \(projectNames.count) · нерешённых: \(unresolvedProjects)") { ForEach(projectNames, id: \.self) { name in Picker("Проект: " + name, selection: Binding(get: { options.projectMapping[name] }, set: { options.projectMapping[name] = $0 })) { Text("По имени / создать").tag(nil as UUID?); ForEach(model.db?.projects ?? []) { Text($0.name).tag(Optional($0.id)) } } } }
                    DisclosureGroup("Распределить строку погашения кредита / ипотеки") {
                        Text("Для внешнего CSV и BeeSave v1: расходная строка со счёта оплаты станет переводом в кредит и отдельными расходами процентов / комиссий. Задайте распределение явно; полная сумма платежа не попадёт в расходы. CSV v2 уже содержит связанные группы.").font(.caption).foregroundStyle(BeeStyle.muted)
                        HStack { TextField("Номер записи после заголовка", text: $financialRow).textFieldStyle(.roundedBorder); Button("Назначить погашением…") { if let row = Int(financialRow), row > 0 { paymentRow = CSVPaymentRow(id: row) } } }
                        ForEach(options.financialPayments.keys.sorted(), id: \.self) { row in
                            HStack { Text("Запись \(row) → " + (options.financialPayments[row].flatMap { mapping in model.db?.financeData.contracts.first { $0.id == mapping.contractID } }.flatMap { contract in model.db?.accounts.first { $0.id == contract.accountID } }?.name ?? "Кредит")); Spacer(); Button("Изменить") { paymentRow = CSVPaymentRow(id: row) }; Button("Снять распределение") { options.financialPayments[row] = nil } }
                        }
                    }
                }
                if stage == 3 {
                    Toggle("Импортировать вероятные дубли внешнего CSV (иначе пропустить)", isOn: $options.importProbableDuplicates).onChange(of: options.importProbableDuplicates) { runPreview() }
                    Button("Обновить предпросмотр", action: runPreview).disabled(working)
                    if let p = preview {
                        Text("Добавить \(p.added.count) · пропустить \(p.skipped) · исключить \(p.excluded) · без курса \(p.missingRates)").font(.headline)
                        Text("Новые справочники: счета \(p.newAccounts.count), категории \(p.newCategories.count), проекты \(p.newProjects.count)")
                        ForEach(p.totals.keys.sorted(), id: \.self) { key in Text(key + ": " + BeeFormat.money(p.totals[key]!, currency: String(key.prefix(3)))) }
                        if !p.probable.isEmpty { Text("Вероятные дубли, записи: " + p.probable.map(String.init).joined(separator: ", ")).foregroundStyle(BeeStyle.warning) }
                        if p.excludedFinancialGroups > 0 { Text("Финансовые группы исключены целиком: \(p.excludedFinancialGroups). Связанные строки не импортируются частично.").font(.caption).foregroundStyle(BeeStyle.warning) }
                        ForEach(p.issues) { issue in HStack(alignment: .top) { Text("Запись \(issue.row), строка \(issue.line), \(issue.field): \(issue.message)").foregroundStyle(BeeStyle.negative); Spacer(); Button("Исключить") { options.excludedRows.insert(issue.row); runPreview() } } }
                        Text("Первые 200 подтверждённых записей").font(.headline)
                        ForEach(firstOperations(p)) { o in Text("\(CalendarDays.label(o.date)) · \(o.kind.title) · \(p.database.accounts.first { $0.id == o.accountID }?.name ?? "") · \(BeeFormat.money(o.amount, currency: p.database.accounts.first { $0.id == o.accountID }?.currency ?? "RUB")) · \(o.comment)").font(.caption) }
                    }
                }
                if stage == 4 { Label("Импорт завершён", systemImage: "checkmark.circle.fill").foregroundStyle(BeeStyle.positive); Text(model.notice ?? "Данные сохранены.") }
                if working { ProgressView(value: progress); Button("Отменить до фиксации") { task?.cancel(); working = false; preview = nil } }
                if !error.isEmpty { Text(error).foregroundStyle(BeeStyle.negative) }
            } }
            Divider(); HStack {
                Button(stage == 4 ? "Закрыть" : "Отмена") { if stage == 4 { dismiss() } else { discard = true } }.keyboardShortcut(.cancelAction)
                Spacer(); if stage > 0 && stage < 4 { Button("Назад") { task?.cancel(); previewRun = UUID(); working = false; stage -= 1; preview = nil } }
                if stage < 3 { Button("Далее") { next() }.buttonStyle(BeePrimaryStyle()).disabled(data == nil || working) }
                if stage == 3 { Button("Импортировать \(preview?.added.count ?? 0) записей") { do { guard let preview, !committed else { return }; committed = true; try model.importPreview(preview); stage = 4; data = nil; self.preview = nil } catch { committed = false; self.error = error.localizedDescription } }.buttonStyle(BeePrimaryStyle()).disabled(preview?.canCommit != true || working || committed) }
            }
        }.padding(24).frame(width: 800, height: 640).foregroundStyle(BeeStyle.text).background(BeeStyle.surface).tint(BeeStyle.honey).interactiveDismissDisabled().onDisappear { task?.cancel(); data = nil; preview = nil }
        .confirmationDialog("Отменить импорт? До фиксации база не изменится.", isPresented: $discard) { Button("Отменить импорт", role: .destructive) { task?.cancel(); dismiss() }; Button("Вернуться", role: .cancel) {} }
        .sheet(item: $paymentRow) { row in CSVFinancialPaymentEditor(row: row.id, initial: options.financialPayments[row.id]) { options.financialPayments[row.id] = $0 } }
    }
    private var unresolvedAccounts: Int { accountNames.filter { name in options.accountMapping[name] == nil && model.db?.accounts.contains(where: { Ledger.normalized($0.name) == Ledger.normalized(name) }) != true }.count }
    private var unresolvedCategories: Int { categoryNames.filter { name in options.categoryMapping[name] == nil && model.db?.categories.contains(where: { Ledger.normalized(model.db?.categoryPath($0.id) ?? "") == Ledger.normalized(name) }) != true }.count }
    private var unresolvedProjects: Int { projectNames.filter { name in options.projectMapping[name] == nil && model.db?.projects.contains(where: { Ledger.normalized($0.name) == Ledger.normalized(name) }) != true }.count }
    private func columnTitle(_ field: String) -> String { ["date": "Дата", "type": "Тип операции", "account_name": "Счёт", "currency": "Валюта", "amount": "Сумма", "income": "Доход", "expense": "Расход", "category_path": "Категория", "project_name": "Проект", "comment": "Комментарий"][field] ?? field }
    private func example(_ field: String) -> String { examples[options.columns[field] ?? field] ?? "—" }

    func choose() { let p = NSOpenPanel(); p.allowedContentTypes = [.commaSeparatedText, .plainText]; guard p.runModal() == .OK, let url = p.url else { return }; do { let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0; guard size <= 104_857_600 else { throw BudgetError.invalid("CSV превышает 100 MiB.") }; data = try Data(contentsOf: url); filename = url.lastPathComponent; if String(data: data!, encoding: .utf8) == nil { options.encoding = "Windows-1251" }; options.separator = CSVCodec.guessSeparator(try CSVCodec.decode(data!, encoding: options.encoding)); readHeaders() } catch { self.error = error.localizedDescription } }
    func readHeaders() { do { guard let data else { return }; let rows = try CSVCodec.parse(CSVCodec.decode(data, encoding: options.encoding), separator: options.separator); headers = rows.first?.fields ?? []; examples = [:]; if let first = rows.dropFirst().first { for (index, name) in headers.enumerated() where index < first.fields.count { examples[name] = String(first.fields[index].prefix(30)) } }; error = ""; preview = nil } catch { self.error = error.localizedDescription } }

    func next() { if stage == 1 { readHeaders(); guard error.isEmpty else { return }; gatherNames() }; stage += 1; if stage == 3 { runPreview() } }
    func gatherNames() { do { guard let data else { return }; let rows = try CSVCodec.parse(CSVCodec.decode(data, encoding: options.encoding), separator: options.separator); func values(_ name: String) -> [String] { let column = options.columns[name] ?? name; guard let i = headers.firstIndex(of: column) else { return [] }; return Array(Set(rows.dropFirst().compactMap { r in guard i < r.fields.count else { return nil }; let s = canonical ? CSVCodec.unprotect(r.fields[i]) : r.fields[i]; return s.isEmpty ? nil : s })).sorted() }; accountNames = Array(Set(values("account_name") + values("to_account_name"))).sorted(); categoryNames = values("category_path"); projectNames = values("project_name"); if !canonical { for name in accountNames where options.newCurrencies[name] == nil { options.newCurrencies[name] = "RUB" } } } catch { self.error = error.localizedDescription } }
    func runPreview() { task?.cancel(); preview = nil; working = true; progress = 0; error = ""; guard let data, let db = model.db else { working = false; return }; let o = options; let run = UUID(); previewRun = run
        task = Task { let worker = Task.detached { var lastProgress = -1.0; return try CSVImporter.preview(data: data, options: o, db: db, cancelled: { Task.isCancelled }, progress: { value in
            if value - lastProgress >= 0.01 { lastProgress = value; Task { @MainActor in if previewRun == run && working { progress = value * 0.95 } } }
        }) }; do { let p = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }; try Task.checkCancellation(); guard previewRun == run else { return }; preview = p; progress = 1; working = false } catch is CancellationError { if previewRun == run { working = false } } catch { if previewRun == run { working = false; self.error = error.localizedDescription } } }
    }
}

private struct CSVPaymentRow: Identifiable { var id: Int }
private struct CSVFinancialPaymentEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var row: Int
    var initial: CSVFinancialPayment?
    var onSave: (CSVFinancialPayment) -> Void
    @State private var contractID: UUID?
    @State private var interest = "0"
    @State private var fee = "0"
    @State private var penalty = "0"
    @State private var received = ""
    @State private var alreadyPosted = false
    @State private var manual = false
    @State private var principal = "0"
    @State private var escrow = "0"
    @State private var escrowAccountID: UUID?
    @State private var escrowReceived = ""
    var contract: FinancialContract? { model.db?.financeData.contracts.first { $0.id == contractID } }
    var currency: String { contract.flatMap { contract in model.db?.accounts.first { $0.id == contract.accountID } }?.currency ?? "RUB" }
    var body: some View {
        EditorFrame(title: "Погашение · запись \(row)", isDirty: true, height: 640, save: save) {
            Picker("Кредит / ипотека", selection: $contractID) { Text("Выберите").tag(nil as UUID?); ForEach(model.db?.financeData.contracts.filter { $0.kind.isDebt && $0.status == .active } ?? []) { contract in Text(model.db?.accounts.first { $0.id == contract.accountID }?.name ?? contract.kind.title).tag(Optional(contract.id)) } }
            Text("Сумма списания берётся из CSV. Все поля ниже — в \(currency). Для разных валют укажите фактическое зачисление; курс не угадывается.").font(.caption)
            money("Зачисление · пусто только при одинаковой валюте", $received)
            money("Проценты", $interest); money("Комиссии", $fee); money("Штраф", $penalty)
            Toggle("Эти расходы уже начислены ранее", isOn: $alreadyPosted)
            money("Взнос escrow · часть суммы списания", $escrow)
            Picker("Счёт escrow", selection: $escrowAccountID) {
                Text("Не выбран").tag(nil as UUID?)
                ForEach(model.db?.accounts.filter { !$0.archived && $0.kind == .ordinary } ?? []) { account in Text(account.name + " · " + account.currency).tag(Optional(account.id)) }
            }
            if let account = model.db?.accounts.first(where: { $0.id == escrowAccountID }), account.currency != currency {
                money("Фактическое зачисление escrow · " + account.currency, $escrowReceived)
            }
            Toggle("Задать распределение перевода вручную", isOn: $manual)
            if manual { money("Погашение тела", $principal); Text("Тело + проценты + комиссии + штраф должны равняться зачислению кредитору. Взнос escrow переводится отдельно и не считается расходом.").font(.caption) }
            Text("Перед фиксацией проверьте созданные операции в предпросмотре импорта.").font(.caption).foregroundStyle(BeeStyle.muted)
        }.onAppear {
            guard let initial else { return }
            contractID = initial.contractID; alreadyPosted = initial.chargesAlreadyPosted; manual = !initial.allocations.isEmpty
            interest = Money.string(initial.interest, currency: currency); fee = Money.string(initial.fee, currency: currency); penalty = Money.string(initial.penalty, currency: currency)
            received = initial.receivedAmount.map { Money.string($0, currency: currency) } ?? ""
            escrow = Money.string(initial.escrowAmount ?? 0, currency: currency); escrowAccountID = initial.escrowAccountID
            let escrowCurrency = model.db?.accounts.first { $0.id == initial.escrowAccountID }?.currency ?? currency
            escrowReceived = initial.escrowReceivedAmount.map { Money.string($0, currency: escrowCurrency) } ?? ""
            principal = Money.string(initial.allocations.filter { $0.component == .principal }.reduce(0) { $0 + $1.amount }, currency: currency)
        }
    }
    private func money(_ title: String, _ value: Binding<String>) -> some View { FormField(title: title) { TextField("0", text: value).textFieldStyle(.roundedBorder) } }
    private func save() throws {
        guard let contract else { throw BudgetError.invalid("Выберите кредит / ипотеку.") }
        func amount(_ value: String) throws -> Int64 { let result = try Money.parse(value.replacingOccurrences(of: ",", with: "."), currency: currency); guard result >= 0 else { throw BudgetError.invalid("Распределение не может быть отрицательным.") }; return result }
        var mapping = CSVFinancialPayment(contractID: contract.id)
        mapping.interest = try amount(interest); mapping.fee = try amount(fee); mapping.penalty = try amount(penalty); mapping.receivedAmount = received.isEmpty ? nil : try amount(received); mapping.chargesAlreadyPosted = alreadyPosted
        let escrowAmount = try amount(escrow)
        if escrowAmount > 0 {
            mapping.escrowAmount = escrowAmount; mapping.escrowAccountID = escrowAccountID
            if !escrowReceived.isEmpty {
                guard let target = model.db?.accounts.first(where: { $0.id == escrowAccountID }) else { throw BudgetError.invalid("Выберите счёт escrow.") }
                mapping.escrowReceivedAmount = try Money.parse(escrowReceived.replacingOccurrences(of: ",", with: "."), currency: target.currency)
            }
        }
        if manual { mapping.allocations = [FinancialAllocation(.principal, try amount(principal)), FinancialAllocation(.interest, mapping.interest), FinancialAllocation(.fee, mapping.fee), FinancialAllocation(.penalty, mapping.penalty)].filter { $0.amount > 0 } }
        onSave(mapping); dismiss()
    }
}


struct RestoreView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var stage = 0
    @State private var url: URL?
    @State private var recovery = ""
    @State private var password = ""
    @State private var repeated = ""
    @State private var preview: (Database, VaultFile, Data)?
    @State private var error = ""
    @State private var confirmed = false
    @State private var working = false
    @State private var discard = false
    @State private var verification: Task<Void, Never>?
    @State private var runID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Восстановить полную копию").font(.title2.bold())
            Text("Шаг \(stage + 1) из 4 · " + ["Файл и ключ", "Проверка", "Локальный вход", "Результат"][stage]).font(.caption).foregroundStyle(BeeStyle.muted)
            ScrollView { VStack(alignment: .leading, spacing: 18) {
                if stage == 0 { Text("Копия заменит текущие данные. Перед заменой будет сохранена проверенная полная копия текущей базы."); Button("Выбрать копию…", action: choose); Text(url?.lastPathComponent ?? "Файл не выбран").font(.caption).foregroundStyle(BeeStyle.muted); FormField(title: "Ключ восстановления этой копии") { SecureField("Полный ключ", text: $recovery).textFieldStyle(.roundedBorder) } }
                if stage == 1 { if working { ProgressView("Проверяем и расшифровываем копию…"); Button("Отменить проверку") { invalidate() } }; if let preview { Label("Копия проверена", systemImage: "checkmark.shield").foregroundStyle(BeeStyle.positive); Text("Счетов: \(preview.0.accounts.count)\nОпераций: \(preview.0.operations.count)\nБюджетов: \(preview.0.budgets.count)\nОтчётов: \(preview.0.reports.count)").lineSpacing(6); Text("Последнее изменение: " + (preview.0.operations.map(\.modifiedAt).max()?.formatted(date: .numeric, time: .shortened) ?? "нет операций")).font(.caption).foregroundStyle(BeeStyle.muted) } else if !working { Button("Повторить проверку", action: verify) } }
                if stage == 2 { FormField(title: "Новый локальный пароль", hint: "Не менее 12 символов") { SecureField("Пароль", text: $password).textFieldStyle(.roundedBorder) }; FormField(title: "Повторите пароль") { SecureField("Повтор", text: $repeated).textFieldStyle(.roundedBorder) }; Text("Ключ восстановления копии продолжит действовать. Для входа используйте новый пароль.").font(.caption).foregroundStyle(BeeStyle.muted); Toggle("Подтверждаю полную замену текущих данных", isOn: $confirmed).toggleStyle(.checkbox) }
                if stage == 3 { Label("Копия восстановлена", systemImage: "checkmark.circle.fill").font(.title3).foregroundStyle(BeeStyle.positive); Text("Бюджет готов к работе. Способы входа доступны в настройках.") }
                if !error.isEmpty { Text(error).foregroundStyle(BeeStyle.negative) }
            }.frame(maxWidth: .infinity, alignment: .leading) }
            Divider(); HStack { Button(stage == 3 ? "Закрыть" : "Отмена") { if stage == 3 || (url == nil && recovery.isEmpty) { dismiss() } else { discard = true } }.keyboardShortcut(.cancelAction); Spacer(); if stage > 0 && stage < 3 { Button("Назад") { invalidate(); password = ""; repeated = ""; stage = 0 } }; if stage < 2 { Button("Далее") { if stage == 0 { stage = 1; verify() } else { stage = 2 } }.buttonStyle(BeePrimaryStyle()).keyboardShortcut(.defaultAction).disabled(stage == 0 ? url == nil || recovery.isEmpty : preview == nil || working) }; if stage == 2 { Button("Заменить данные", action: restore).buttonStyle(BeePrimaryStyle()).keyboardShortcut(.defaultAction).disabled(!confirmed || password.count < 12 || password != repeated || preview == nil || model.busy) } }
        }.padding(24).frame(width: 600, height: 550).foregroundStyle(BeeStyle.text).background(BeeStyle.surface).tint(BeeStyle.honey).interactiveDismissDisabled()
            .onChange(of: recovery) { invalidate() }.onDisappear { invalidate(); recovery = ""; password = ""; repeated = "" }
            .confirmationDialog("Закрыть восстановление? Текущие данные сохранятся.", isPresented: $discard) { Button("Закрыть", role: .destructive) { dismiss() }; Button("Продолжить", role: .cancel) {} }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.data]
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let selected = panel.url else { return }
            invalidate(); url = selected
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }
    private func invalidate() { verification?.cancel(); runID = UUID(); preview = nil; confirmed = false; working = false; error = "" }
    private func verify() { guard let url else { return }; invalidate(); working = true; let token = UUID(); runID = token; let key = recovery
        verification = Task { let worker = Task.detached { try VaultStore(url: url).previewRestore(from: url, recovery: key) }; do { let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }); try Task.checkCancellation(); guard token == runID else { return }; preview = result; working = false } catch is CancellationError {} catch { guard token == runID else { return }; working = false; self.error = error.localizedDescription } }
    }
    private func restore() { do { guard password == repeated, let preview, confirmed else { throw BudgetError.invalid("Проверьте копию и подтвердите замену.") }; try model.restore(preview, newPassword: password); stage = 3; self.preview = nil; recovery = ""; password = ""; repeated = "" } catch { self.error = error.localizedDescription } }
}
