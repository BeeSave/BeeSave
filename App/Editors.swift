import SwiftUI
import BudgetCore

struct AccountEditor: View {
    @EnvironmentObject var model: AppModel; var id: UUID?
    @State private var name = ""; @State private var currency = "RUB"; @State private var opened = Day.today.rawValue; @State private var balance = "0"; @State private var archived = false
    var body: some View { EditorFrame(title: id == nil ? "Новый счёт" : "Изменить счёт", save: save) {
        TextField("Название", text: $name); CurrencyPicker(title: "Валюта", selection: $currency).disabled(id != nil && model.db?.operations.contains { $0.accountID == id || $0.toAccountID == id } == true)
        DayField(title: "Дата открытия", value: $opened)
        if id == nil { TextField("Начальный остаток (со знаком)", text: $balance); Text("Начальный остаток создаёт отдельное событие и не считается доходом.").foregroundStyle(.secondary) }
        else { Toggle("Архивирован", isOn: $archived); Text("Для сверки остатка используйте корректировку. Счёт с историей можно архивировать.").foregroundStyle(.secondary) }
    }.onAppear { if let a = model.db?.accounts.first(where: { $0.id == id }) { name = a.name; currency = a.currency; opened = a.openedOn.rawValue; archived = a.archived } else { currency = model.db?.settings.baseCurrency ?? "RUB" } } }
    func save() throws { guard let db = model.db else { throw BudgetError.locked }; var a = db.accounts.first { $0.id == id } ?? Account(name: name, currency: currency); a.name = name; a.currency = currency; a.openedOn = try Day(opened); a.archived = archived; let initial = id == nil ? try Money.parse(balance, currency: currency) : nil; try model.commit { try Ledger.saveAccount(a, opening: initial, in: &$0) } }
}
struct OperationEditor: View {
    @EnvironmentObject var model: AppModel; var id: UUID?; var kind: OperationKind
    @State private var accountID: UUID?; @State private var toID: UUID?; @State private var date = Day.today.rawValue; @State private var amount = ""; @State private var received = ""; @State private var categoryID: UUID?; @State private var projectID: UUID?; @State private var comment = ""; @State private var mode = BudgetMode.automatic; @State private var rates: [FXRate] = []; @State private var manualRate = ""; @State private var target = "RUB"; @State private var rateDate = Day.today.rawValue; @State private var fetched: FXRate?; @State private var fetching = false; @State private var rateError = ""; @State private var cacheConfirmed = false; @State private var currencyConfirmed = false; @State private var loaded = false
    var account: Account? { model.db?.accounts.first { $0.id == accountID } }
    var destination: Account? { model.db?.accounts.first { $0.id == toID } }
    var active: [Account] { model.db?.accounts.filter { !$0.archived } ?? [] }
    var changedCurrency: Bool { guard let old = model.db?.operations.first(where: { $0.id == id }), let previous = model.db?.accounts.first(where: { $0.id == old.accountID }) else { return false }; return previous.currency != account?.currency }
    var direction: String { if let a = account, let b = destination, let v = try? Money.parse(amount, currency: a.currency), let r = try? Money.parse(received, currency: b.currency), let ratio = try? Money.ratio(from: v, currency: a.currency, to: r, toCurrency: b.currency) { return "1 \(a.currency) = \(ratio) \(b.currency)" }; return "Введите обе суммы или рассчитайте зачисление по курсу." }
    var body: some View { EditorFrame(title: (id == nil ? "Новый " : "Изменить ") + kind.title.lowercased(), canSave: !active.isEmpty && !fetching, save: save) {
        if active.isEmpty { EmptyState(title: "Нет активных счетов", detail: "Создайте счёт или верните счёт из архива.") }
        DayField(title: "Дата", value: $date)
        Picker(kind == .income ? "Счёт зачисления" : "Счёт списания", selection: $accountID) { Text("Выберите счёт").tag(nil as UUID?); ForEach(active) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) } }
        TextField("Сумма · \(account?.currency ?? "—")", text: $amount)
        if changedCurrency { Toggle("Подтверждаю новую сумму в \(account?.currency ?? "")", isOn: $currencyConfirmed) }
        if kind == .transfer {
            Picker("Счёт получения", selection: $toID) { Text("Выберите счёт").tag(nil as UUID?); ForEach(active.filter { $0.id != accountID }) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) } }
            TextField("Фактически зачислено · \(destination?.currency ?? "—")", text: $received)
            Text(direction).font(.callout.monospaced()).textSelection(.enabled)
            if destination?.currency != account?.currency { TextField("Курс: 1 \(account?.currency ?? "") = X \(destination?.currency ?? "")", text: $manualRate); HStack { Button("Получить курс") { fetchTransfer() }.disabled(fetching || toID == nil); Button("Рассчитать зачисление") { calculateTransfer() }.disabled(accountID == nil || toID == nil) }; if let fetched { Text(fetched.label).font(.caption) } }
            Text("Сохранённые суммы не изменяются при обновлении справочных курсов. Комиссия учитывается отдельным расходом.").font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Категория", selection: $categoryID) { Text("Без категории").tag(nil as UUID?); ForEach(model.db?.categories.filter { $0.kind == kind && !$0.archived && $0.parentID.flatMap { id in model.db?.categories.first { $0.id == id } }?.archived != true } ?? []) { Text(model.db?.categoryPath($0.id) ?? $0.name).tag(Optional($0.id)) } }
            Picker("Проект", selection: $projectID) { Text("Без проекта").tag(nil as UUID?); ForEach(model.db?.projects.filter { !$0.archived } ?? []) { Text($0.name).tag(Optional($0.id)) } }
            if kind == .expense { Picker("Участие в бюджетах", selection: $mode) { ForEach(BudgetMode.allCases, id: \.self) { Text($0.title).tag($0) } } }
            GroupBox("Исторические курсы") { VStack(alignment: .leading, spacing: 10) {
                Text("Без курса операция сохранится в исходной валюте, а сводки будут помечены неполными. Курс закрепляется за операцией.").font(.caption).foregroundStyle(.secondary)
                ForEach(rates) { r in HStack { Text(r.label + (r.revision > 0 ? " · исправлен" : "")).font(.caption); Spacer(); Button("Убрать") { rates.removeAll { $0.id == r.id } } } }
                CurrencyPicker(title: "Валюта пересчёта", selection: $target)
                TextField("1 \(account?.currency ?? "") = X \(target)", text: $manualRate)
                DayField(title: "Дата действия курса", value: $rateDate)
                HStack { Button("Получить на дату операции") { fetchSnapshot() }.disabled(fetching || account == nil || account?.currency == target); Button("Добавить ручной курс") { addManual() }.disabled(account == nil || account?.currency == target) }
                if let fetched { Text(fetched.label).font(.caption); Button("Закрепить полученный курс") { addRate(fetched) } }
                if let a = account, let cache = model.db?.rates.filter({ $0.date <= (try? Day(date)) ?? .today && (($0.base == a.currency && $0.quote == target) || ($0.quote == a.currency && $0.base == target)) }).sorted(by: { $0.date > $1.date }).first {
                    Text("Кеш: \(cache.label)\(cache.stale ? " · устаревший" : "")").font(.caption).foregroundStyle(.orange)
                    Toggle("Подтверждаю использование этого кеша", isOn: $cacheConfirmed)
                    Button("Закрепить кеш") { do { let value = try Reports.rate(from: a.currency, to: target, rates: [cache], on: try Day(date)); if let value { addRate(FXRate(base: a.currency, quote: target, rate: value, date: cache.date, provider: cache.provider)) } } catch { rateError = error.localizedDescription } }.disabled(!cacheConfirmed)
                }
            } }
        }
        if fetching { ProgressView("Получение курса…"); Button("Отменить запрос") { fetching = false; rateRequest?.cancel() } }
        if !rateError.isEmpty { Text(rateError).foregroundStyle(.orange) }
        TextField(kind == .adjustment ? "Причина" : "Комментарий", text: $comment, axis: .vertical).lineLimit(3...5)
        if let a = account { Text("Текущий остаток: " + Money.display((try? model.db?.balance(a.id)) ?? 0, currency: a.currency)).font(.caption).foregroundStyle(.secondary) }
    }.onAppear(perform: load).onChange(of: accountID) { old, new in if loaded && old != new { let oldCurrency = model.db?.accounts.first { $0.id == old }?.currency; if oldCurrency != account?.currency { amount = ""; rates = []; fetched = nil; manualRate = ""; currencyConfirmed = false }; if kind == .transfer && destination?.currency == account?.currency { received = amount } } }.onChange(of: date) { _, value in if let d = try? Day(value) { rateDate = d.rawValue; fetched = nil } }.onDisappear { rateRequest?.cancel() } }
    @State private var rateRequest: Task<Void, Never>?
    func load() {
        guard !loaded else { return }; target = model.db?.settings.baseCurrency ?? "RUB"
        if let o = model.db?.operations.first(where: { $0.id == id }), let a = model.db?.accounts.first(where: { $0.id == o.accountID }) { accountID = o.accountID; toID = o.toAccountID; date = o.date.rawValue; rateDate = date; amount = Money.string(o.amount, currency: a.currency); if let r = o.toAmount, let to = model.db?.accounts.first(where: { $0.id == o.toAccountID }) { received = Money.string(r, currency: to.currency) }; categoryID = o.categoryID; projectID = o.projectID; comment = o.comment; mode = o.budgetMode; rates = o.fx; manualRate = o.transferRate ?? "" }
        else { accountID = active.first?.id; toID = active.dropFirst().first?.id }
        loaded = true
    }
    func save() throws {
        guard let db = model.db, let a = account else { throw BudgetError.invalid("Выберите активный счёт.") }; var o = db.operations.first { $0.id == id } ?? Operation(kind: kind, accountID: a.id, amount: 0)
        o.accountID = a.id; o.date = try Day(date); o.amount = try Money.parse(amount, currency: a.currency); o.comment = comment; o.fx = rates
        if kind == .transfer { guard let b = destination else { throw BudgetError.invalid("Выберите счёт получения.") }; o.toAccountID = b.id; o.toAmount = try Money.parse(a.currency == b.currency ? amount : received, currency: b.currency) }
        else { o.categoryID = categoryID; o.projectID = projectID; o.budgetMode = mode }
        try model.commit { try Ledger.saveOperation(o, currencyConfirmed: currencyConfirmed, in: &$0) }
    }
    func addRate(_ rate: FXRate) { var r = rate; if let old = rates.first(where: { $0.base == r.base && $0.quote == r.quote }) { r.revision = old.revision + 1 }; rates.removeAll { $0.base == r.base && $0.quote == r.quote }; rates.append(r); rateError = "" }
    func addManual() { do { guard let a = account else { return }; let r = FXRate(base: a.currency, quote: target, rate: manualRate.replacingOccurrences(of: ",", with: "."), date: try Day(rateDate)); try Ledger.validateRate(r); guard r.date <= (try Day(date)) else { throw BudgetError.invalid("Курс не может быть позже операции.") }; addRate(r) } catch { rateError = error.localizedDescription } }
    func fetchSnapshot() { guard let a = account else { return }; fetch(base: a.currency, quote: target) }
    func fetchTransfer() { guard let a = account, let b = destination else { return }; fetch(base: a.currency, quote: b.currency) }
    func fetch(base: String, quote: String) {
        rateRequest?.cancel(); fetching = true; rateError = ""
        rateRequest = Task { do { let r = try await RateClient().fetch(base: base, quote: quote, on: try Day(date)); try Task.checkCancellation(); fetched = r; manualRate = r.rate; rateDate = r.date.rawValue; fetching = false } catch is CancellationError { fetching = false } catch { fetching = false; rateError = error.localizedDescription + " Можно ввести курс вручную." } }
    }
    func calculateTransfer() { do { guard let a = account, let b = destination else { return }; let v = try Money.parse(amount, currency: a.currency); received = Money.string(try Money.convert(v, from: a.currency, to: b.currency, rate: a.currency == b.currency ? "1" : manualRate.replacingOccurrences(of: ",", with: ".")), currency: b.currency) } catch { rateError = error.localizedDescription } }
}

struct ReconcileEditor: View {
    @EnvironmentObject var model: AppModel; var accountID: UUID?; @State private var selected: UUID?; @State private var actual = ""; @State private var reason = ""
    var account: Account? { model.db?.accounts.first { $0.id == selected } }
    var body: some View { EditorFrame(title: "Сверить остаток", save: save) {
        Picker("Счёт", selection: $selected) { ForEach(model.db?.accounts.filter { !$0.archived } ?? []) { Text($0.name).tag(Optional($0.id)) } }
        Text("Дата: \(Day.today.rawValue). Сверка учитывает все операции сегодняшнего дня.")
        if let a = account { Text("Учётный остаток: " + Money.display((try? model.db?.balance(a.id)) ?? 0, currency: a.currency)); TextField("Фактический остаток · \(a.currency)", text: $actual); if let balance = try? model.db?.balance(a.id), let value = try? Money.parse(actual, currency: a.currency) { let (difference, overflow) = value.subtractingReportingOverflow(balance); if !overflow { Text("Разница: " + Money.display(difference, currency: a.currency)).foregroundStyle(difference < 0 ? .red : .primary) } } }
        TextField("Причина сверки", text: $reason); Text("Разница фиксируется. Позднейшая правка старых операций изменит остаток, но не эту корректировку. При совпадении новая запись не создаётся.").foregroundStyle(.secondary)
    }.onAppear { selected = accountID ?? model.db?.accounts.first { !$0.archived }?.id } }
    func save() throws { guard let a = account else { throw BudgetError.invalid("Выберите счёт.") }; let value = try Money.parse(actual, currency: a.currency); try model.commit { _ = try Ledger.reconcile(accountID: a.id, observed: value, reason: reason, in: &$0) } }
}
struct CategoryEditor: View {
    @EnvironmentObject var model: AppModel; var id: UUID?; @State private var name = ""; @State private var kind = OperationKind.expense; @State private var parent: UUID?
    var body: some View { EditorFrame(title: "Категория", save: save) {
        TextField("Название", text: $name); Picker("Тип", selection: $kind) { Text("Расходы").tag(OperationKind.expense); Text("Доходы").tag(OperationKind.income) }.onChange(of: kind) { parent = nil }
        Picker("Родитель", selection: $parent) { Text("Категория первого уровня").tag(nil as UUID?); ForEach(model.db?.categories.filter { $0.parentID == nil && !$0.archived && $0.kind == kind && $0.id != id } ?? []) { Text($0.name).tag(Optional($0.id)) } }
        Text("Доступны два уровня. Использованную подкатегорию нельзя переносить между родителями.").font(.caption).foregroundStyle(.secondary)
    }.onAppear { if let c = model.db?.categories.first(where: { $0.id == id }) { name = c.name; kind = c.kind; parent = c.parentID } } }
    func save() throws { var c = model.db?.categories.first { $0.id == id } ?? BudgetCore.Category(name: name, kind: kind); c.name = name; c.kind = kind; c.parentID = parent; try model.commit { try Ledger.saveCategory(c, in: &$0) } }
}
struct ProjectEditor: View {
    @EnvironmentObject var model: AppModel; var id: UUID?; @State private var name = ""; @State private var description = ""
    var body: some View { EditorFrame(title: "Проект", save: save) { TextField("Название", text: $name); TextField("Описание", text: $description, axis: .vertical).lineLimit(4...8) }.onAppear { if let p = model.db?.projects.first(where: { $0.id == id }) { name = p.name; description = p.description } } }
    func save() throws { var p = model.db?.projects.first { $0.id == id } ?? Project(name: name); p.name = name; p.description = description; try model.commit { try Ledger.saveProject(p, in: &$0) } }
}
