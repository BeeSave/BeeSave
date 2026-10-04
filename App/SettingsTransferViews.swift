import SwiftUI
import UniformTypeIdentifiers
import BudgetCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel; @State private var current = ""; @State private var recoveryAuth = false; @State private var passwordOn = true; @State private var touchID = false; @State private var newPassword = ""; @State private var repeatPassword = ""; @State private var accessMessage = ""; @State private var updating = false; @State private var manualBase = "USD"; @State private var manualQuote = "RUB"; @State private var rateValue = ""; @State private var rateDay = Day.today.rawValue
    var body: some View { Group { if let db = model.db { TabView {
        Form {
            CurrencyPicker(title: "Базовая валюта", selection: Binding(get: { model.db?.settings.baseCurrency ?? "RUB" }, set: { c in model.perform { $0.settings.baseCurrency = c } }))
            Text("Валюты счетов, бюджетов и сохранённые снимки не изменяются.").foregroundStyle(.secondary)
            Picker("Автоблокировка", selection: Binding(get: { model.db?.settings.lockMinutes ?? 5 }, set: { m in model.perform { $0.settings.lockMinutes = m } })) { Text("1 минута").tag(1); Text("5 минут").tag(5); Text("15 минут").tag(15); Text("30 минут").tag(30); Text("Не блокировать по таймеру").tag(0) }
            Text("База блокируется при блокировке Mac и сне. При блокировке несохранённые формы закрываются.")
        }.padding(24).tabItem { Label("Общие", systemImage: "gearshape") }
        Form {
            Toggle("Вход паролем", isOn: $passwordOn); Toggle("Touch ID", isOn: $touchID).disabled(!LocalKeys.biometricAvailable())
            if !LocalKeys.keychainEntitled() { Text("Для Touch ID и входа без пароля требуется подписанная сборка с правами Keychain. Пока доступен вход паролем.").font(.caption).foregroundStyle(.secondary) }
            if !passwordOn && !touchID { Text("Шифрование сохраняется. В вашей разблокированной сессии macOS приложение откроется без дополнительного входа.").foregroundStyle(.orange) }
            Toggle("Подтвердить ключом восстановления", isOn: $recoveryAuth)
            SecureField(recoveryAuth ? "Текущий ключ восстановления" : "Текущий пароль (или Touch ID ниже)", text: $current)
            if passwordOn { SecureField("Новый пароль (пусто — оставить текущий)", text: $newPassword); SecureField("Повторите новый пароль", text: $repeatPassword) }
            Text("Для изменения требуется текущий способ входа. Новый путь проверяется до удаления прежнего. Если вход отключён, macOS подтвердит владельца.").font(.caption).foregroundStyle(.secondary)
            Button("Применить способы входа") { updating = true; Task { do { guard newPassword == repeatPassword else { throw BudgetError.invalid("Новые пароли не совпали.") }; try await model.changeAccess(current: current, useRecovery: recoveryAuth, passwordEnabled: passwordOn, newPassword: newPassword, touchID: touchID); accessMessage = "Настройки защиты сохранены."; current = ""; newPassword = ""; repeatPassword = "" } catch { accessMessage = error.localizedDescription }; updating = false } }.disabled(updating)
            Text(accessMessage).foregroundStyle(.secondary)
        }.padding(24).tabItem { Label("Защита", systemImage: "lock.shield") }
        ScrollView { VStack(alignment: .leading, spacing: 12) {
            HStack { Button("Обновить курсы") { model.refreshRates() }.disabled(model.rateBusy); if model.rateBusy { ProgressView(); Button("Отменить") { model.rateTask?.cancel() } } }
            Text("Справочные курсы не гарантируют банковский курс сделки. Запросы содержат только валюты и дату; суммы пересчитываются локально.").font(.caption).foregroundStyle(.secondary)
            ForEach(db.rates.sorted { $0.base < $1.base }) { Text($0.label + ($0.stale ? " · устаревший" : "")).font(.caption).textSelection(.enabled) }
            Divider(); Text("Ручной справочный курс").font(.headline); CurrencyPicker(title: "От", selection: $manualBase); CurrencyPicker(title: "К", selection: $manualQuote); TextField("1 \(manualBase) = X \(manualQuote)", text: $rateValue); DayField(title: "Дата", value: $rateDay)
            Button("Добавить в кеш") { do { let r = FXRate(base: manualBase, quote: manualQuote, rate: rateValue.replacingOccurrences(of: ",", with: "."), date: try Day(rateDay)); try Ledger.validateRate(r); try model.commit { $0.rates.append(r) }; rateValue = "" } catch { model.error = error.localizedDescription } }
            Text("Для исправления исторического снимка откройте нужную операцию и явно добавьте курс. Новые курсы не меняют старые снимки.").font(.caption).foregroundStyle(.secondary)
        }.padding(24) }.tabItem { Label("Курсы", systemImage: "arrow.triangle.2.circlepath") }
        Form {
            Text("Автоматические копии: \(model.backupFolder.path)").textSelection(.enabled)
            Text("Последняя успешная: \(db.settings.lastBackup?.formatted(date: .numeric, time: .shortened) ?? "ещё нет")")
            Text("30 дневных и 10 служебных копий; ручные не удаляются. Копии зашифрованы; для переноса нужен ключ восстановления.")
            Button("Выбрать папку автокопий…") { model.changeBackupFolder() }; Button("Сохранить полную копию…") { model.manualBackup() }; Button("Восстановить полную копию…") { model.sheet = SheetRoute(kind: .restore) }
            if let e = model.backupError { Text(e).foregroundStyle(.red) }
            Divider(); Button("Импорт CSV…") { model.sheet = SheetRoute(kind: .importCSV) }; Button("Экспорт всех операций…") { model.exportCSV() }
        }.padding(24).tabItem { Label("Копии и CSV", systemImage: "externaldrive") }
    }.onAppear { passwordOn = model.bootstrap?.password != nil; touchID = model.bootstrap?.touchID ?? false } }
    else { EmptyState(title: "База закрыта", detail: "Войдите в основном окне. До входа настройки и финансовые данные скрыты.", icon: "lock") } }
        .onChange(of: model.db == nil) { if model.db == nil { current = ""; newPassword = ""; repeatPassword = ""; accessMessage = ""; rateValue = "" } }
    }
}

struct ImportView: View {
    @EnvironmentObject var model: AppModel; @Environment(\.dismiss) var dismiss
    @State private var data: Data?; @State private var filename = ""; @State private var options = ImportOptions(); @State private var headers: [String] = []; @State private var stage = 0; @State private var preview: ImportPreview?; @State private var error = ""; @State private var working = false; @State private var progress = 0.0; @State private var task: Task<Void, Never>?; @State private var accountNames: [String] = []; @State private var categoryNames: [String] = []; @State private var projectNames: [String] = []; @State private var discard = false; @State private var committed = false
    var canonical: Bool { headers.contains("schema_version") && headers.contains("operation_id") }
    @State private var previewRun = UUID()
    func firstOperations(_ p: ImportPreview) -> [BudgetCore.Operation] {
        let ids = Set(p.added)
        return Array(p.database.operations.lazy.filter { ids.contains($0.id) }.prefix(200))
    }
    let columns = ["date", "type", "account_name", "currency", "amount", "income", "expense", "category_path", "project_name", "comment"]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Импорт CSV").font(.title2.bold()); Text("\(stage + 1) / 5 · " + ["Выбор файла", "Формат и колонки", "Сопоставление", "Проверка и подтверждение", "Результат"][stage]).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 12) {
                if stage == 0 { Text("До подтверждения база не изменяется. Исходный CSV не сохраняется в приложении или копиях."); Button("Выбрать CSV…", action: choose); Text(filename) }
                if stage == 1 {
                    Picker("Кодировка", selection: $options.encoding) { Text("UTF-8").tag("UTF-8"); Text("Windows-1251").tag("Windows-1251") }
                    Picker("Разделитель", selection: $options.separator) { Text("Запятая").tag(UInt8(44)); Text("Точка с запятой").tag(UInt8(59)); Text("Табуляция").tag(UInt8(9)) }
                    Button("Перечитать заголовки", action: readHeaders)
                    if canonical { Text("Обнаружен BeeSave CSV версии 1. Даты ISO, десятичная точка, UUID и курсовые снимки сохраняются.") }
                    else {
                        Picker("Формат даты (выберите явно)", selection: $options.dateFormat) { Text("YYYY-MM-DD").tag("ISO"); Text("DD/MM/YYYY").tag("DMY"); Text("MM/DD/YYYY").tag("MDY") }
                        Picker("Десятичный знак", selection: $options.decimalSeparator) { Text("Точка").tag("."); Text("Запятая").tag(",") }
                        Picker("Правило суммы", selection: $options.signRule) { Text("Положительная сумма и колонка типа").tag("type"); Text("Отрицательная — расход, положительная — доход").tag("signed"); Text("Отдельные доход и расход").tag("separate") }
                        ForEach(columns, id: \.self) { field in Picker(field, selection: Binding(get: { options.columns[field] ?? (headers.contains(field) ? field : "") }, set: { options.columns[field] = $0 })) { Text("Не используется").tag(""); ForEach(headers, id: \.self) { Text($0).tag($0) } } }
                    }
                }
                if stage == 2 {
                    Toggle("Разрешить создание неизвестных счетов, категорий и проектов", isOn: $options.createReferences)
                    Text("Новые счета начинают с нулевого остатка; начальные события переносятся только из BeeSave CSV. Для другого остатка создайте счёт заранее.").font(.caption).foregroundStyle(.secondary)
                    ForEach(accountNames, id: \.self) { name in GroupBox(name) { VStack(alignment: .leading) {
                        Picker("Сопоставить счёт", selection: Binding(get: { options.accountMapping[name] }, set: { options.accountMapping[name] = $0 })) { Text("По имени / создать").tag(nil as UUID?); ForEach(model.db?.accounts ?? []) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) } }
                        if !canonical && options.accountMapping[name] == nil && model.db?.accounts.contains(where: { Ledger.normalized($0.name) == Ledger.normalized(name) }) != true { CurrencyPicker(title: "Валюта нового счёта", selection: Binding(get: { options.newCurrencies[name] ?? "RUB" }, set: { options.newCurrencies[name] = $0 })); TextField("Дата открытия YYYY-MM-DD", text: Binding(get: { options.newOpenedOn[name]?.rawValue ?? "" }, set: { options.newOpenedOn[name] = try? Day($0) })) }
                        if let existing = options.accountMapping[name] ?? model.db?.accounts.first(where: { Ledger.normalized($0.name) == Ledger.normalized(name) })?.id { TextField("Явно изменить дату открытия (необязательно)", text: Binding(get: { options.earlierOpening[existing]?.rawValue ?? "" }, set: { options.earlierOpening[existing] = try? Day($0) })) }
                    } } }
                    ForEach(categoryNames, id: \.self) { name in Picker("Категория: " + name, selection: Binding(get: { options.categoryMapping[name] }, set: { options.categoryMapping[name] = $0 })) { Text("По пути / создать").tag(nil as UUID?); ForEach(model.db?.categories ?? []) { Text(model.db?.categoryPath($0.id) ?? $0.name).tag(Optional($0.id)) } } }
                    ForEach(projectNames, id: \.self) { name in Picker("Проект: " + name, selection: Binding(get: { options.projectMapping[name] }, set: { options.projectMapping[name] = $0 })) { Text("По имени / создать").tag(nil as UUID?); ForEach(model.db?.projects ?? []) { Text($0.name).tag(Optional($0.id)) } } }
                }
                if stage == 3 {
                    Toggle("Импортировать вероятные дубли внешнего CSV (иначе пропустить)", isOn: $options.importProbableDuplicates).onChange(of: options.importProbableDuplicates) { runPreview() }
                    Button("Обновить предпросмотр", action: runPreview).disabled(working)
                    if let p = preview {
                        Text("Добавить \(p.added.count) · пропустить \(p.skipped) · исключить \(p.excluded) · без курса \(p.missingRates)").font(.headline)
                        Text("Новые справочники: счета \(p.newAccounts.count), категории \(p.newCategories.count), проекты \(p.newProjects.count)")
                        ForEach(p.totals.keys.sorted(), id: \.self) { key in Text(key + ": " + Money.display(p.totals[key]!, currency: String(key.prefix(3)))) }
                        if !p.probable.isEmpty { Text("Вероятные дубли, записи: " + p.probable.map(String.init).joined(separator: ", ")).foregroundStyle(.orange) }
                        ForEach(p.issues) { issue in HStack(alignment: .top) { Text("Запись \(issue.row), строка \(issue.line), \(issue.field): \(issue.message)").foregroundStyle(.red); Spacer(); Button("Исключить") { options.excludedRows.insert(issue.row); runPreview() } } }
                        Text("Первые 200 подтверждённых записей").font(.headline)
                        ForEach(firstOperations(p)) { o in Text("\(o.date.rawValue) · \(o.kind.title) · \(p.database.accounts.first { $0.id == o.accountID }?.name ?? "") · \(o.amount) минимальных единиц · \(o.comment)").font(.caption) }
                    }
                }
                if stage == 4 { Label("Импорт завершён", systemImage: "checkmark.circle.fill").foregroundStyle(.teal); Text(model.notice ?? "Данные сохранены.") }
                if working { ProgressView(value: progress); Button("Отменить до фиксации") { task?.cancel(); working = false; preview = nil } }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            } }
            Divider(); HStack {
                Button(stage == 4 ? "Закрыть" : "Отмена") { if stage == 4 { dismiss() } else { discard = true } }.keyboardShortcut(.cancelAction)
                Spacer(); if stage > 0 && stage < 4 { Button("Назад") { task?.cancel(); previewRun = UUID(); working = false; stage -= 1; preview = nil } }
                if stage < 3 { Button("Далее") { next() }.buttonStyle(.borderedProminent).disabled(data == nil || working) }
                if stage == 3 { Button("Подтвердить импорт") { do { guard let preview, !committed else { return }; committed = true; try model.importPreview(preview); stage = 4; data = nil; self.preview = nil } catch { committed = false; self.error = error.localizedDescription } }.buttonStyle(.borderedProminent).disabled(preview?.canCommit != true || working || committed) }
            }
        }.padding(24).frame(width: 800, height: 720).interactiveDismissDisabled().onDisappear { task?.cancel(); data = nil; preview = nil }
        .confirmationDialog("Отменить импорт? До фиксации база не изменится.", isPresented: $discard) { Button("Отменить импорт", role: .destructive) { task?.cancel(); dismiss() }; Button("Вернуться", role: .cancel) {} }
    }
    func choose() { let p = NSOpenPanel(); p.allowedContentTypes = [.commaSeparatedText, .plainText]; guard p.runModal() == .OK, let url = p.url else { return }; do { let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0; guard size <= 104_857_600 else { throw BudgetError.invalid("CSV превышает 100 MiB.") }; data = try Data(contentsOf: url); filename = url.lastPathComponent; if String(data: data!, encoding: .utf8) == nil { options.encoding = "Windows-1251" }; options.separator = CSVCodec.guessSeparator(try CSVCodec.decode(data!, encoding: options.encoding)); readHeaders() } catch { self.error = error.localizedDescription } }
    func readHeaders() { do { guard let data else { return }; headers = try CSVCodec.parse(CSVCodec.decode(data, encoding: options.encoding), separator: options.separator).first?.fields ?? []; error = ""; preview = nil } catch { self.error = error.localizedDescription } }
    func next() { if stage == 1 { readHeaders(); guard error.isEmpty else { return }; gatherNames() }; stage += 1; if stage == 3 { runPreview() } }
    func gatherNames() { do { guard let data else { return }; let rows = try CSVCodec.parse(CSVCodec.decode(data, encoding: options.encoding), separator: options.separator); func values(_ name: String) -> [String] { let column = options.columns[name] ?? name; guard let i = headers.firstIndex(of: column) else { return [] }; return Array(Set(rows.dropFirst().compactMap { r in guard i < r.fields.count else { return nil }; let s = canonical ? CSVCodec.unprotect(r.fields[i]) : r.fields[i]; return s.isEmpty ? nil : s })).sorted() }; accountNames = Array(Set(values("account_name") + values("to_account_name"))).sorted(); categoryNames = values("category_path"); projectNames = values("project_name"); if !canonical { for name in accountNames where options.newCurrencies[name] == nil { options.newCurrencies[name] = "RUB" } } } catch { self.error = error.localizedDescription } }
    func runPreview() { task?.cancel(); preview = nil; working = true; progress = 0; error = ""; guard let data, let db = model.db else { working = false; return }; let o = options; let run = UUID(); previewRun = run
        task = Task { let worker = Task.detached { var lastProgress = -1.0; return try CSVImporter.preview(data: data, options: o, db: db, cancelled: { Task.isCancelled }, progress: { value in
            if value - lastProgress >= 0.01 { lastProgress = value; Task { @MainActor in if previewRun == run && working { progress = value * 0.95 } } }
        }) }; do { let p = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }; try Task.checkCancellation(); guard previewRun == run else { return }; preview = p; progress = 1; working = false } catch is CancellationError { if previewRun == run { working = false } } catch { if previewRun == run { working = false; self.error = error.localizedDescription } } }
    }
}

struct RestoreView: View {
    @EnvironmentObject var model: AppModel; @Environment(\.dismiss) var dismiss; @State private var url: URL?; @State private var recovery = ""; @State private var password = ""; @State private var repeatPassword = ""; @State private var preview: (Database, VaultFile, Data)?; @State private var error = ""; @State private var confirmed = false
    var body: some View { EditorFrame(title: "Восстановить полную копию", saveTitle: "Заменить данные", canSave: preview != nil && confirmed, save: save) {
        Text("Восстановление полностью заменяет текущие данные. Перед заменой создаётся проверенная копия. Файл сначала расшифровывается и проверяется в памяти.")
        Button("Выбрать копию…") { let p = NSOpenPanel(); p.allowedContentTypes = [.data]; guard p.runModal() == .OK else { return }; url = p.url; preview = nil; confirmed = false }; Text(url?.lastPathComponent ?? "Файл не выбран")
        SecureField("Ключ восстановления этой копии", text: $recovery).onChange(of: recovery) { preview = nil; confirmed = false }
        Button("Проверить копию") { do { guard let url else { throw BudgetError.invalid("Выберите файл.") }; preview = try model.vault.previewRestore(from: url, recovery: recovery); error = "" } catch { preview = nil; self.error = error.localizedDescription } }
        if let p = preview { Text("Схема \(p.0.version) · счетов \(p.0.accounts.count) · операций \(p.0.operations.count) · бюджетов \(p.0.budgets.count) · отчётов \(p.0.reports.count)").font(.headline); Text("Последнее изменение: \(p.0.operations.map(\.modifiedAt).max()?.formatted() ?? "нет операций")")
            SecureField("Новый локальный пароль: не менее 12 символов", text: $password); SecureField("Повторите пароль", text: $repeatPassword); Text("Touch ID потребуется включить заново. Ключ восстановления этой копии продолжит действовать.").font(.caption); Toggle("Подтверждаю полную замену текущих данных", isOn: $confirmed) }
        if !error.isEmpty { Text(error).foregroundStyle(.red) }
    }.onDisappear { preview = nil; recovery = ""; password = ""; repeatPassword = "" } }
    func save() throws { guard password == repeatPassword else { throw BudgetError.invalid("Пароли не совпали.") }; guard let preview else { throw BudgetError.invalid("Проверьте копию.") }; try model.restore(preview, newPassword: password) }
}
