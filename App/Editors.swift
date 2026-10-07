import SwiftUI
import BudgetCore
import BudgetPresentation

struct AccountEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var id: UUID?
    var onSaved: (UUID) -> Void = { _ in }
    @State private var accountID = UUID()
    @State private var name = ""
    @State private var currency = "RUB"
    @State private var opened = Day.today.rawValue
    @State private var balance = "0"
    @State private var archived = false
    @State private var kind = AccountKind.ordinary
    @State private var bankID: String?
    @State private var contract: FinancialContract?
    @State private var fieldErrors: [String: String] = [:]
    @State private var loaded = false
    @State private var original = ""
    @FocusState private var focused: Bool
    private var value: String { [name, currency, opened, balance, String(archived), kind.rawValue, bankID ?? "", contract.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""].joined(separator: "|") }
    var body: some View {
        EditorFrame(title: id == nil ? "Новый счёт" : "Изменить счёт", isDirty: loaded && value != original, height: kind == .ordinary ? 580 : 740, save: save) {
            FormField(title: "Название") { TextField("Название счёта", text: $name).textFieldStyle(BeeTextFieldStyle()).focused($focused) }
            FinanceChoice(title: "Тип счёта", value: $kind, titleOf: { $0.title }).disabled(model.db?.contract(for: accountID) != nil)
            CurrencyPicker(title: "Валюта счёта", selection: $currency).disabled(id != nil && model.db?.operations.contains { $0.accountID == id || $0.toAccountID == id } == true)
            BankPicker(bankID: $bankID)
            if id == nil { FormField(title: "Начальный остаток · \(currency)", hint: kind.isDebt ? "Задолженность укажите со знаком минус. Лимит задаётся отдельно и не увеличивает остаток." : "Начальный остаток не считается доходом.") { TextField("0", text: $balance).textFieldStyle(BeeTextFieldStyle()) } }
            DayField(title: "Дата открытия учёта", value: $opened)
            if id != nil { Toggle("Счёт в архиве", isOn: $archived).toggleStyle(.checkbox) }
            if contract != nil { FinancialContractFields(contract: Binding(get: { contract! }, set: { contract = $0 }), currency: currency, errors: $fieldErrors) }
        }.onAppear { load() }.onChange(of: kind) { _, next in
            if next == .ordinary { contract = nil }
            else if contract?.kind != next { contract = FinancialContract(accountID: accountID, kind: next, start: (try? Day(opened)) ?? .today, end: next == .revolvingCredit ? nil : .today.adding(365)) }
        }
    }
    private func load() {
        guard !loaded else { return }
        if let account = model.db?.accounts.first(where: { $0.id == id }) { accountID = account.id; name = account.name; currency = account.currency; opened = account.openedOn.rawValue; archived = account.archived; kind = account.kind; bankID = account.bankID; contract = model.db?.contract(for: account.id) }
        else { currency = model.db?.settings.baseCurrency ?? "RUB" }
        original = value; loaded = true; focused = true
    }
    private func save() throws {
        guard fieldErrors.isEmpty else { throw BudgetError.invalid(fieldErrors.values.sorted().joined(separator: "\n")) }
        guard let db = model.db else { throw BudgetError.locked }
        var account = db.accounts.first { $0.id == id } ?? Account(name: name, currency: currency)
        account.id = accountID; account.name = name; account.currency = currency; account.openedOn = try Day(opened); account.archived = archived; account.bankID = bankID
        let initial = id == nil ? try Money.parse(balance, currency: currency) : nil
        var savedContract = contract
        if id == nil, initial != nil { savedContract?.originalPrincipal = initial! < 0 ? try FinanceMath.positiveMagnitude(initial!) : initial! }
        try model.commit { candidate in
            try Ledger.saveAccount(account, opening: initial, in: &candidate)
            if let savedContract { try FinancialLedger.saveContract(savedContract, in: &candidate) }
        }
        onSaved(account.id)
    }
}

private enum NestedEditor: String, Identifiable { case account, category, project; var id: String { rawValue } }
private enum TransferMethod: String, CaseIterable { case actual = "Фактическая сумма", reference = "Справочный курс", manual = "Ручной курс" }

struct OperationEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var id: UUID?
    var kind: OperationKind
    var accountContext: UUID?
    @State private var financeComponent = FinancialComponent.principal
    @State private var transactionKind = CreditTransactionKind.purchase
    @State private var violationConfirmed = false
    @State private var consequenceUnknown = true
    @State private var accountID: UUID?
    @State private var toID: UUID?
    @State private var date = Day.today.rawValue
    @State private var amount = ""
    @State private var received = ""
    @State private var categoryID: UUID?
    @State private var projectID: UUID?
    @State private var comment = ""
    @State private var mode = BudgetMode.automatic
    @State private var rates: [FXRate] = []
    @State private var manualRate = ""
    @State private var target = "RUB"
    @State private var rateDate = Day.today.rawValue
    @State private var fetched: FXRate?
    @State private var fetching = false
    @State private var rateError = ""
    @State private var cacheConfirmed = false
    @State private var currencyConfirmed = false
    @State private var loaded = false
    @State private var original: [String] = []
    @State private var details = false
    @State private var rateExpanded = false
    @State private var nested: NestedEditor?
    @State private var transferMethod = TransferMethod.actual
    @State private var rateRequest: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var initializing = true
    @FocusState private var focus: String?
    var account: Account? { model.db?.accounts.first { $0.id == accountID } }
    var destination: Account? { model.db?.accounts.first { $0.id == toID } }
    var active: [Account] { model.db?.accounts.filter { !$0.archived } ?? [] }
    var changedCurrency: Bool { guard let old = model.db?.operations.first(where: { $0.id == id }), let previous = model.db?.accounts.first(where: { $0.id == old.accountID }) else { return false }; return previous.currency != account?.currency }
    var showRates: Bool { kind.isFlow && (account.map { $0.currency != model.db?.settings.baseCurrency || $0.currency != model.db?.settings.reportCurrency } == true || !rates.isEmpty) }
    var missingRate: Bool { guard kind.isFlow, let db = model.db, let account, let day = try? Day(date) else { return false }; return Set([db.settings.baseCurrency, db.settings.reportCurrency]).contains { $0 != account.currency && (try? Reports.rate(from: account.currency, to: $0, rates: rates, on: day)) == nil } }
    private var value: [String] { [accountID?.uuidString ?? "", toID?.uuidString ?? "", date, amount, received, categoryID?.uuidString ?? "", projectID?.uuidString ?? "", comment, mode.rawValue, rates.map { $0.label + String($0.revision) }.joined(), String(currencyConfirmed), financeComponent.rawValue, transactionKind.rawValue, String(violationConfirmed), String(consequenceUnknown)] }
    private var direction: String { guard let account, let destination, let amount = try? Money.parse(amount, currency: account.currency), let received = try? Money.parse(received, currency: destination.currency), let ratio = try? Money.ratio(from: amount, currency: account.currency, to: received, toCurrency: destination.currency) else { return "Зачисление будет показано после ввода суммы" }; return "1 \(account.currency) = \(BeeFormat.rate(ratio)) \(destination.currency)" }
    var body: some View {
        EditorFrame(title: (id == nil ? "Новый " : "Изменить ") + kind.title.lowercased(), saveTitle: missingRate ? "Сохранить без курса" : "Сохранить", canSave: account != nil && (kind != .transfer || destination != nil), isDirty: loaded && value != original, height: kind == .transfer ? 620 : 590, onError: locateError, save: save) {
            if active.isEmpty && id == nil {
                EmptyState(title: "Нет активных счетов", detail: "Создайте счёт или верните его из архива.", icon: "wallet.bifold")
                Button("Создать счёт") { focus = nil; nested = .account }.buttonStyle(BeePrimaryStyle())
                ForEach(model.db?.accounts.filter(\.archived) ?? []) { account in Button("Вернуть «\(account.name)» из архива") { model.perform { db in var copy = account; copy.archived = false; try Ledger.saveAccount(copy, in: &db) }; accountID = account.id } }
            } else {
                FormField(title: "Сумма \(kind == .transfer ? "списания" : "") · \(account?.currency ?? "выберите счёт")") { TextField("0,00", text: $amount).textFieldStyle(BeeTextFieldStyle()).beeFont(.system(size: 28, weight: .semibold)).focused($focus, equals: "amount") }
                if changedCurrency { Toggle("Подтверждаю сумму в \(account?.currency ?? "")", isOn: $currencyConfirmed).toggleStyle(.checkbox) }
                FormField(title: kind == .income ? "Счёт зачисления" : "Счёт списания") { HStack { accountPicker(selection: $accountID, excluding: nil); Button { focus = nil; nested = .account } label: { Image(systemName: "plus") }.help("Создать счёт") } }
                if account?.kind.isDebt == true && kind == .expense {
                    FinanceChoice(title: "Вид операции по кредиту", value: $transactionKind, titleOf: { $0.title })
                    FormField(title: "Компонент долга") { BeePicker("Компонент", selection: $financeComponent) { ForEach([FinancialComponent.principal, .interest, .fee, .penalty, .unallocated], id: \.self) { Text($0.title).tag($0) } }.labelsHidden() }
                }
                if kind == .transfer { transferFields }
                if !depositWarnings.isEmpty { ForEach(depositWarnings, id: \.self) { Text($0).beeFont(.caption).foregroundStyle(BeeStyle.warning) }; Toggle("Подтверждаю фактическое движение с нарушением условий", isOn: $violationConfirmed); Toggle("Последствия пока неизвестны; прогноз будет неполным", isOn: $consequenceUnknown) }
                if kind != .transfer {
                    FormField(title: "Категория") { HStack { BeePicker("Категория", selection: $categoryID) { Text("Без категории").tag(nil as UUID?); ForEach(model.db?.categories.filter { $0.kind == kind && ((!$0.archived && $0.parentID.flatMap { id in model.db?.categories.first { $0.id == id } }?.archived != true) || $0.id == categoryID) } ?? []) { category in Text((model.db?.categoryPath(category.id) ?? category.name) + (category.archived ? " · архив" : "")).tag(Optional(category.id)) } }.labelsHidden(); Button { focus = nil; nested = .category } label: { Image(systemName: "plus") }.help("Создать категорию") } }
                }
                DayField(title: "Дата операции", value: $date)
                DisclosureGroup(mode == .excluded ? "Дополнительно · вне бюджетов" : "Дополнительно", isExpanded: $details) {
                    VStack(alignment: .leading, spacing: 14) {
                        if kind.isFlow {
                            FormField(title: "Проект") { HStack { BeePicker("Проект", selection: $projectID) { Text("Без проекта").tag(nil as UUID?); ForEach(model.db?.projects.filter { !$0.archived || $0.id == projectID } ?? []) { Text($0.name + ($0.archived ? " · архив" : "")).tag(Optional($0.id)) } }.labelsHidden(); Button { focus = nil; nested = .project } label: { Image(systemName: "plus") }.help("Создать проект") } }
                            if kind == .expense { FormField(title: "Участие в бюджетах") { BeePicker("Участие", selection: $mode) { ForEach(BudgetMode.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden() } }
                        }
                        FormField(title: "Комментарий") { TextField("Необязательно", text: $comment, axis: .vertical).textFieldStyle(BeeTextFieldStyle()).lineLimit(2...4).focused($focus, equals: "comment") }
                    }.padding(.top, 12)
                }
                if showRates { rateFields }
                if let account { Text("Текущий остаток: " + BeeFormat.money((try? model.db?.balance(account.id)) ?? 0, currency: account.currency)).beeFont(.caption).foregroundStyle(BeeStyle.muted) }
            }
        }.task { load(); await Task.yield(); initializing = false }.onChange(of: accountID) { old, new in
            guard loaded && !initializing && old != new else { return }; cancelRequest(); let oldCurrency = model.db?.accounts.first { $0.id == old }?.currency
            if let oldCurrency, oldCurrency != account?.currency { amount = ""; rates = []; fetched = nil; manualRate = ""; currencyConfirmed = false; focus = "amount" }
            if toID == new { toID = nil }; updateTransfer()
        }.onChange(of: toID) { guard !initializing else { return }; cancelRequest(); fetched = nil; manualRate = ""; received = ""; updateTransfer() }
            .onChange(of: date) { guard !initializing else { return }; cancelRequest(); if let day = try? Day(date) { rateDate = day.rawValue }; fetched = nil; cacheConfirmed = false }
            .onChange(of: target) { guard !initializing else { return }; cancelRequest(); fetched = nil; manualRate = ""; cacheConfirmed = false }
            .onChange(of: amount) { guard !initializing else { return }; updateTransfer() }.onChange(of: manualRate) { guard !initializing else { return }; updateTransfer() }.onChange(of: transferMethod) { cancelRequest(); updateTransfer() }
            .onChange(of: nested) { if nested == nil { focus = "amount" } }
            .onDisappear { cancelRequest() }
            .sheet(item: $nested) { editor in switch editor { case .account: AccountEditor(id: nil, onSaved: { accountID = $0 }); case .category: CategoryEditor(id: nil, initialKind: kind, onSaved: { categoryID = $0 }); case .project: ProjectEditor(id: nil, onSaved: { projectID = $0 }) } }
    }
    @ViewBuilder private func accountPicker(selection: Binding<UUID?>, excluding: UUID?) -> some View {
        BeePicker("Счёт", selection: selection) { Text("Выберите счёт").tag(nil as UUID?); ForEach(model.db?.accounts.filter { $0.id != excluding && (!$0.archived || $0.id == selection.wrappedValue) } ?? []) { Text($0.name + " · " + $0.currency + ($0.archived ? " · архив" : "")).tag(Optional($0.id)) } }.labelsHidden()
    }
    @ViewBuilder private var transferFields: some View {
        FormField(title: "Счёт получения") { accountPicker(selection: $toID, excluding: accountID) }
        if active.count < 2 { Button("Создать второй счёт") { focus = nil; nested = .account } }
        if let account, let destination {
            if account.currency == destination.currency { Text("Будет зачислено: " + ((try? Money.parse(amount, currency: account.currency)).map { BeeFormat.money($0, currency: destination.currency) } ?? "—")).beeFont(.headline) }
            else {
                FormField(title: "Как определить зачисление") { BeePicker("Способ", selection: $transferMethod) { ForEach(TransferMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden() }
                if transferMethod == .actual { FormField(title: "Фактически зачислено · \(destination.currency)") { TextField("0,00", text: $received).textFieldStyle(BeeTextFieldStyle()).focused($focus, equals: "received") } }
                else if transferMethod == .manual { FormField(title: "1 \(account.currency) = X \(destination.currency)") { TextField("Курс", text: $manualRate).textFieldStyle(BeeTextFieldStyle()).focused($focus, equals: "rate") } }
                else { Button("Получить курс на дату операции") { fetch(base: account.currency, quote: destination.currency, transfer: true) }.disabled(fetching); if let fetched { Text(fetched.label).beeFont(.caption).foregroundStyle(BeeStyle.muted) } }
                if transferMethod != .actual { Text("Будет зачислено: " + ((try? Money.parse(received, currency: destination.currency)).map { BeeFormat.money($0, currency: destination.currency) } ?? "—")).beeFont(.headline) }
                Text(direction).beeFont(.caption.monospaced()).foregroundStyle(BeeStyle.muted)
            }
            Text("Комиссию добавьте отдельным расходом.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        }
        requestStatus
    }
    @ViewBuilder private var rateFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            if missingRate { Label("Без курса сводки будут частичными. Сумма сохранится в валюте счёта.", systemImage: "exclamationmark.triangle").beeFont(.caption).foregroundStyle(BeeStyle.warning) }
            ForEach(rates) { rate in HStack { Text(rate.label + (rate.revision > 0 ? " · исправлен" : "")).beeFont(.caption); Spacer(); Button("Убрать") { rates.removeAll { $0.id == rate.id } }.controlSize(.small) } }
            DisclosureGroup("Курс пересчёта", isExpanded: $rateExpanded) { VStack(alignment: .leading, spacing: 12) {
                CurrencyPicker(title: "Валюта пересчёта", selection: $target)
                Button("Получить и закрепить курс") { guard let account else { return }; fetch(base: account.currency, quote: target, transfer: false) }.disabled(fetching || account?.currency == target)
                FormField(title: "1 \(account?.currency ?? "—") = X \(target)") { TextField("Ручной курс", text: $manualRate).textFieldStyle(BeeTextFieldStyle()).focused($focus, equals: "rate") }
                DayField(title: "Дата действия курса", value: $rateDate)
                Button("Закрепить ручной курс", action: addManual).disabled(account?.currency == target)
                if let account, let cache = model.db?.rates.filter({ $0.date <= ((try? Day(date)) ?? .today) && (($0.base == account.currency && $0.quote == target) || ($0.quote == account.currency && $0.base == target)) }).sorted(by: { $0.date > $1.date }).first {
                    Text("Кеш: \(cache.label)\(cache.stale ? " · устарел" : "")").beeFont(.caption).foregroundStyle(BeeStyle.warning)
                    Toggle("Подтверждаю использование кеша", isOn: $cacheConfirmed).toggleStyle(.checkbox)
                    Button("Закрепить кеш") { do { if let value = try Reports.rate(from: account.currency, to: target, rates: [cache], on: Day(date)) { addRate(FXRate(base: account.currency, quote: target, rate: value, date: cache.date, provider: cache.provider)) } } catch { rateError = error.localizedDescription } }.disabled(!cacheConfirmed)
                }
                requestStatus
            }.padding(.top, 10) }
        }
    }
    @ViewBuilder private var requestStatus: some View { if fetching { HStack { ProgressView().controlSize(.small); Text("Получаем курс…").beeFont(.caption); Button("Отменить") { cancelRequest() } } }; if !rateError.isEmpty { Text(rateError).beeFont(.caption).foregroundStyle(BeeStyle.warning) } }
    private func load() {
        guard !loaded else { return }; target = model.db?.settings.baseCurrency ?? "RUB"
        if let operation = model.db?.operations.first(where: { $0.id == id }), let account = model.db?.accounts.first(where: { $0.id == operation.accountID }) {
            accountID = operation.accountID; toID = operation.toAccountID; date = operation.date.rawValue; rateDate = date; amount = Money.string(operation.amount, currency: account.currency)
            if let value = operation.toAmount, let destination = model.db?.accounts.first(where: { $0.id == operation.toAccountID }) { received = Money.string(value, currency: destination.currency) }
            financeComponent = operation.financial?.component ?? .principal; transactionKind = operation.financial?.transactionKind ?? .purchase; violationConfirmed = operation.financial?.contractViolationConfirmed ?? false; consequenceUnknown = operation.financial?.consequenceUnknown ?? true
            categoryID = operation.categoryID; projectID = operation.projectID; comment = operation.comment; mode = operation.budgetMode; rates = operation.fx; details = true; rateExpanded = !rates.isEmpty
        } else if let db = model.db { accountID = EditorContext.account(in: db, kind: kind, context: accountContext) }
        if target == account?.currency { target = model.db?.settings.reportCurrency ?? target }
        original = value; loaded = true; focus = "amount"
    }
    private func save() throws {
        cancelRequest(); guard let db = model.db, let account else { throw BudgetError.invalid("Выберите счёт.") }; var operation = db.operations.first { $0.id == id } ?? Operation(kind: kind, accountID: account.id, amount: 0)
        operation.accountID = account.id; operation.date = try Day(date); operation.amount = try Money.parse(amount, currency: account.currency); operation.comment = comment; operation.fx = rates
        if kind == .transfer { guard let destination else { throw BudgetError.invalid("Выберите счёт получения.") }; operation.toAccountID = destination.id; operation.toAmount = try Money.parse(account.currency == destination.currency ? amount : received, currency: destination.currency) }
        else { operation.categoryID = categoryID; operation.projectID = projectID; operation.budgetMode = mode }
        if account.kind.isDebt || violationConfirmed {
            var metadata = operation.financial ?? FinanceOperationDetails(); metadata.component = financeComponent; metadata.transactionKind = transactionKind; metadata.contractID = db.contract(for: account.id)?.id
            metadata.contractViolationConfirmed = violationConfirmed; metadata.consequenceUnknown = violationConfirmed && consequenceUnknown; operation.financial = metadata
        }
        try model.commit { try Ledger.saveOperation(operation, currencyConfirmed: currencyConfirmed, in: &$0) }
    }
    private var depositWarnings: [String] {
        guard kind == .transfer, let account, let destination, let db = model.db, let parsed = try? Money.parse(amount, currency: account.currency), let day = try? Day(date) else { return [] }
        var operation = Operation(kind: .transfer, date: day, accountID: account.id, amount: parsed); if let id { operation.id = id }; operation.toAccountID = destination.id
        return (try? FinancialLedger.depositWarnings(operation, db: db)) ?? []
    }
    private func locateError(_ error: String) { if error.contains("курс") { rateExpanded = true; focus = "rate" } else if error.contains("коммент") { details = true; focus = "comment" } else { focus = "amount" } }
    private func addRate(_ rate: FXRate) { var next = rate; if let old = rates.first(where: { $0.base == next.base && $0.quote == next.quote }) { next.revision = old.revision + 1 }; rates.removeAll { $0.base == next.base && $0.quote == next.quote }; rates.append(next); rateError = "" }
    private func addManual() { do { guard let account else { return }; let rate = FXRate(base: account.currency, quote: target, rate: manualRate.replacingOccurrences(of: ",", with: "."), date: try Day(rateDate)); try Ledger.validateRate(rate); guard rate.date <= (try Day(date)) else { throw BudgetError.invalid("Курс не может быть позже операции.") }; addRate(rate) } catch { rateError = error.localizedDescription; focus = "rate" } }
    private func cancelRequest() { requestID = UUID(); rateRequest?.cancel(); rateRequest = nil; fetching = false }
    private func fetch(base: String, quote: String, transfer: Bool) {
        cancelRequest(); let token = UUID(); requestID = token; fetching = true; rateError = ""; let requestedDate = date
        rateRequest = Task { do { let rate = try await RateClient().fetch(base: base, quote: quote, on: Day(requestedDate)); try Task.checkCancellation(); guard token == requestID, model.db != nil else { return }; fetched = rate; manualRate = rate.rate; rateDate = rate.date.rawValue; if transfer { updateTransfer() } else { addRate(rate) }; fetching = false } catch is CancellationError {} catch { guard token == requestID else { return }; fetching = false; rateError = error.localizedDescription + " Доступен ручной ввод." } }
    }
    private func updateTransfer() { guard kind == .transfer, let account, let destination else { return }; if account.currency == destination.currency { received = amount; return }; guard transferMethod != .actual else { return }; do { received = Money.string(try Money.convert(Money.parse(amount, currency: account.currency), from: account.currency, to: destination.currency, rate: manualRate.replacingOccurrences(of: ",", with: ".")), currency: destination.currency) } catch { received = "" } }
}

struct ReconcileEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var accountID: UUID?
    @State private var selected: UUID?
    @State private var actual = ""
    @State private var reason = ""
    @State private var original: [String] = []
    @State private var loaded = false
    @FocusState private var focus: Bool
    private var delta: Int64? { guard let db = model.db, let selected, let account = try? db.account(selected), let value = try? Money.parse(actual, currency: account.currency), let balance = try? db.balance(selected) else { return nil }; let (delta, overflow) = value.subtractingReportingOverflow(balance); return overflow ? nil : delta }
    var body: some View {
        EditorFrame(title: "Сверить остаток", saveTitle: delta == 0 ? "Остаток совпадает" : "Сохранить корректировку", canSave: delta != nil, isDirty: loaded && [selected?.uuidString ?? "", actual, reason] != original, height: 480, onError: { _ in focus = true }, save: {
            guard let db = model.db, let selected, let account = try? db.account(selected), let delta else { throw BudgetError.invalid("Укажите фактический остаток.") }; if delta != 0 { let amount = try Money.parse(actual, currency: account.currency); try model.commit { _ = try Ledger.reconcile(accountID: selected, observed: amount, reason: reason, in: &$0) } }
        }) {
            if let db = model.db {
                if let account = db.accounts.first(where: { $0.id == accountID }) { Text(account.name).beeFont(.headline); Text("На " + CalendarDays.label(.today, full: true) + " · все операции текущего дня").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
                else { FormField(title: "Счёт") { BeePicker("Счёт", selection: $selected) { Text("Выберите").tag(nil as UUID?); ForEach(db.accounts.filter { !$0.archived }) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden() } }
                if let selected, let account = try? db.account(selected) { Text("Учётный остаток: " + BeeFormat.money((try? db.balance(selected)) ?? 0, currency: account.currency)).foregroundStyle(BeeStyle.muted); FormField(title: "Фактический остаток · \(account.currency)") { TextField("0,00", text: $actual).textFieldStyle(BeeTextFieldStyle()).focused($focus) }; if let delta { Text(delta == 0 ? "Остатки совпадают — запись не требуется" : "Корректировка: " + BeeFormat.money(delta, currency: account.currency)).beeFont(.headline).foregroundStyle(delta < 0 ? BeeStyle.negative : BeeStyle.positive) } }
                FormField(title: "Причина сверки", hint: "Обязательна при расхождении остатков.") { TextField("Кратко объясните расхождение", text: $reason).textFieldStyle(BeeTextFieldStyle()) }
            }
        }.onAppear { guard !loaded else { return }; selected = accountID; original = [selected?.uuidString ?? "", actual, reason]; loaded = true; focus = true }
    }
}

struct CategoryEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var id: UUID?
    var initialKind = OperationKind.expense
    var onSaved: (UUID) -> Void = { _ in }
    @State private var name = ""
    @State private var kind = OperationKind.expense
    @State private var parent: UUID?
    @State private var loaded = false
    @State private var original: [String] = []
    @FocusState private var focus: Bool
    private var value: [String] { [name, kind.rawValue, parent?.uuidString ?? ""] }
    var body: some View {
        EditorFrame(title: id == nil ? "Новая категория" : "Изменить категорию", isDirty: loaded && value != original, height: 410, onError: { _ in focus = true }, save: save) {
            FormField(title: "Название") { TextField("Название категории", text: $name).textFieldStyle(BeeTextFieldStyle()).focused($focus) }
            FormField(title: "Для операций") { BeePicker("Тип", selection: Binding(get: { kind }, set: { kind = $0; parent = nil })) { Text("Расходы").tag(OperationKind.expense); Text("Доходы").tag(OperationKind.income) }.labelsHidden().disabled(id != nil) }
            FormField(title: "Родительская категория") { BeePicker("Родитель", selection: $parent) { Text("Первый уровень").tag(nil as UUID?); ForEach(model.db?.categories.filter { $0.parentID == nil && !$0.archived && $0.kind == kind && $0.id != id } ?? []) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden() }
            Text("Доступны два уровня. Использованную подкатегорию нельзя переносить.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        }.onAppear { guard !loaded else { return }; kind = initialKind; if let category = model.db?.categories.first(where: { $0.id == id }) { name = category.name; kind = category.kind; parent = category.parentID }; original = value; loaded = true; focus = true }
    }
    private func save() throws { var category = model.db?.categories.first { $0.id == id } ?? BudgetCore.Category(name: name, kind: kind); category.name = name; category.kind = kind; category.parentID = parent; try model.commit { try Ledger.saveCategory(category, in: &$0) }; onSaved(category.id) }
}

struct ProjectEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var id: UUID?
    var onSaved: (UUID) -> Void = { _ in }
    @State private var name = ""
    @State private var description = ""
    @State private var loaded = false
    @State private var original: [String] = []
    @FocusState private var focus: Bool
    var body: some View {
        EditorFrame(title: id == nil ? "Новый проект" : "Изменить проект", isDirty: loaded && [name, description] != original, height: 430, onError: { _ in focus = true }, save: save) { FormField(title: "Название") { TextField("Название проекта", text: $name).textFieldStyle(BeeTextFieldStyle()).focused($focus) }; FormField(title: "Описание") { TextField("Необязательно", text: $description, axis: .vertical).textFieldStyle(BeeTextFieldStyle()).lineLimit(3...5) } }
            .onAppear { guard !loaded else { return }; if let project = model.db?.projects.first(where: { $0.id == id }) { name = project.name; description = project.description }; original = [name, description]; loaded = true; focus = true }
    }
    private func save() throws { var project = model.db?.projects.first { $0.id == id } ?? Project(name: name); project.name = name; project.description = description; try model.commit { try Ledger.saveProject(project, in: &$0) }; onSaved(project.id) }
}
