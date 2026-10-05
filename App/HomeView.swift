import SwiftUI
import BudgetCore
import BudgetPresentation

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack { Image(systemName: "circle.hexagongrid.fill").foregroundStyle(BeeStyle.honey); Text("BeeSave").font(.title2.bold()); Spacer() }.padding(22)
                ScrollView { VStack(spacing: 6) { ForEach(SectionID.allCases) { item in
                    Button { model.section = item } label: {
                        HStack(spacing: 12) { Image(systemName: item.icon).frame(width: 20); Text(item.rawValue); Spacer() }
                            .font(.subheadline.weight(model.section == item ? .semibold : .regular)).padding(.horizontal, 12).padding(.vertical, 11)
                            .foregroundStyle(model.section == item ? BeeStyle.honeyText : BeeStyle.onBackground)
                            .background(model.section == item ? BeeStyle.honey : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).accessibilityAddTraits(model.section == item ? .isSelected : [])
                } }.padding(.horizontal, 12) }

                HStack { SettingsLink { Label("Настройки", systemImage: "gearshape") }; Spacer(); Button { model.lock() } label: { Image(systemName: "lock") }.help("Заблокировать бюджет · ⇧⌘L") }.buttonStyle(.plain).padding(20)
            }.foregroundStyle(BeeStyle.onBackground).background(BeeStyle.chrome).navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 230)
        } detail: {
            VStack(spacing: 0) {
                if let message = model.backupError { HStack { Label(message, systemImage: "exclamationmark.triangle.fill"); Spacer(); Button("Выбрать папку") { model.changeBackupFolder() } }.font(.caption).padding(12).foregroundStyle(BeeStyle.negative).background(BeeStyle.surface) }
                if let notice = model.notice { HStack { Text(notice).font(.caption); Spacer(); Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Закрыть сообщение") }.padding(.horizontal, 24).padding(.vertical, 10).background(BeeStyle.chrome.opacity(0.4)) }
                switch model.section {
                case .dashboard: DashboardView()
                case .accounts: AccountsView()
                case .expenses: OperationsView(kind: .expense)
                case .incomes: OperationsView(kind: .income)
                case .budgets: BudgetsView()
                case .references: ReferencesView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).beeWindow().navigationTitle("")

        }.sheet(isPresented: Binding(get: { model.drilldown != nil }, set: { if !$0 { model.drilldown = nil } })) {
            VStack(spacing: 0) { HStack { Text(model.drilldownTitle).font(.title2.bold()); Spacer(); Button("Закрыть") { model.drilldown = nil }.keyboardShortcut(.cancelAction) }.padding(22); OperationsView(ids: model.drilldown, initialFilters: model.drilldownFilters) }.frame(width: 960, height: 640).beeWindow()
        }
    }
}

struct AccountsView: View {
    @EnvironmentObject var model: AppModel
    @State private var archived = false
    var body: some View { if let db = model.db {
        if let id = model.historyAccount, let account = db.accounts.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Button("Все счета", systemImage: "chevron.left") { model.historyAccount = nil }; Text(account.name).font(.title2.bold()); Spacer(); Text(BeeFormat.money((try? db.balance(id)) ?? 0, currency: account.currency)).font(.title2).monospacedDigit() }.padding(.horizontal, 24).padding(.top, 20)
                HStack {
                    if account.archived { Label("Счёт в архиве", systemImage: "archivebox"); Button("Вернуть из архива") { model.perform { db in var copy = account; copy.archived = false; try Ledger.saveAccount(copy, in: &db) } } }
                    else { Button("Добавить расход") { model.newOperation(.expense, account: id) }.buttonStyle(BeePrimaryStyle()); Button("Добавить доход") { model.newOperation(.income, account: id) }; Button("Перевести") { model.newOperation(.transfer, account: id) }; Spacer(); Button("Сверить остаток") { model.sheet = SheetRoute(kind: .reconciliation, entityID: id) } }
                }.padding(.horizontal, 24)
                OperationsView(accountID: id)
            }
        } else { ScrollView { VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: "Мои счета") { Toggle("Архив", isOn: $archived).toggleStyle(.checkbox); Button("Новый счёт", systemImage: "plus") { model.sheet = SheetRoute(kind: .account) }.buttonStyle(BeePrimaryStyle()) }
            if db.accounts.isEmpty { EmptyState(title: "Добавьте первый счёт", detail: "Карта, накопления или наличные — валюта и начальный остаток.", icon: "wallet.bifold").beeCard() }
            VStack(spacing: 0) { ForEach(db.accounts.filter { archived || !$0.archived }) { account in
                let balance = (try? db.balance(account.id)) ?? 0
                HStack(spacing: 14) {
                    Image(systemName: account.archived ? "archivebox" : "creditcard").foregroundStyle(BeeStyle.expense).frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) { Button(account.name) { model.openHistory(account.id) }.buttonStyle(.plain).font(.headline); Text(account.currency + (account.archived ? " · архив" : "")).font(.caption).foregroundStyle(BeeStyle.muted) }
                    Spacer(); Text(BeeFormat.money(balance, currency: account.currency)).font(.title3).monospacedDigit().foregroundStyle(balance < 0 ? BeeStyle.negative : BeeStyle.text)
                    Button("История", systemImage: "chevron.right") { model.openHistory(account.id) }
                    Menu { Button("Изменить") { model.sheet = SheetRoute(kind: .account, entityID: account.id) }; Button("Сверить остаток") { model.sheet = SheetRoute(kind: .reconciliation, entityID: account.id) }.disabled(account.archived)
                        Button(account.archived ? "Вернуть из архива" : "Архивировать") { if account.archived || confirmDeletion(account.name, consequence: "История и остаток сохранятся. Новые операции будут недоступны.") { model.perform { db in var copy = account; copy.archived.toggle(); try Ledger.saveAccount(copy, in: &db) } } }
                        Button("Удалить", role: .destructive) { if confirmDeletion(account.name, consequence: "Удаляется пустой счёт без ссылок. Для счёта с историей используйте архив.") { model.perform { try Ledger.deleteAccount(account.id, in: &$0) } } }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                }.padding(.vertical, 14)
                if account.id != db.accounts.filter({ archived || !$0.archived }).last?.id { Divider() }
            } }.beeCard()
        }.padding(26) } }
    } }
}

struct OperationsView: View {
    @EnvironmentObject var model: AppModel
    var kind: OperationKind?
    var accountID: UUID?
    var ids: [UUID]?
    var initialPeriod: Filters
    @State private var filters: Filters
    @State private var selected: UUID?
    @State private var editor: SheetRoute?
    @State private var sortOrder = [KeyPathComparator(\OperationTableEntry.date, order: .reverse)]
    init(kind: OperationKind? = nil, accountID: UUID? = nil, ids: [UUID]? = nil, initialFilters: Filters = Filters()) { self.kind = kind; self.accountID = accountID; self.ids = ids; self.initialPeriod = initialFilters; _filters = State(initialValue: initialFilters) }
    var operations: [BudgetCore.Operation] { guard let db = model.db else { return [] }; var candidate = filters; if let accountID { candidate.accounts = [accountID] }; var rows = Reports.selected(db, filters: candidate, kinds: kind.map { [$0] }, sorted: false); if let ids { let allowed = Set(ids); rows = rows.filter { allowed.contains($0.id) } }; return rows }
    private var tableRows: [OperationTableEntry] { guard let db = model.db else { return [] }; let accounts = Dictionary(uniqueKeysWithValues: db.accounts.map { ($0.id, $0) }); return operations.map { OperationTableEntry(operation: $0, source: accounts[$0.accountID], context: accountID.flatMap { accounts[$0] }) }.sorted(using: sortOrder) }
    private var exportFilters: Filters { var value = filters; if let accountID { value.accounts = [accountID] }; return value }
    var body: some View { if let db = model.db {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: ids != nil ? "Детализация" : kind == .expense ? "Расходы" : kind == .income ? "Доходы" : "История") {
                Button("Экспорт…") { model.exportCSV(selection: operations, filters: exportFilters) }
                if let kind { Button(kind == .expense ? "Добавить расход" : "Добавить доход", systemImage: "plus") { model.newOperation(kind) }.buttonStyle(BeePrimaryStyle()) }
            }
            FilterBar(filters: $filters, showParticipation: kind != .income, kind: kind, fixedAccount: accountID, operationIDs: ids, resetPeriod: initialPeriod)
            HStack { TextField("Поиск по комментарию", text: $filters.search).textFieldStyle(.roundedBorder); Text("\(operations.count) записей").font(.caption).foregroundStyle(BeeStyle.backgroundMuted) }
            if operations.isEmpty {
                VStack { EmptyState(title: db.operations.contains(where: { $0.kind.isFlow }) ? "Нет совпадений" : "Операций пока нет", detail: "Добавьте операцию или измените выборку."); Button("Сбросить фильтры") { filters = Filters() } }.beeCard().frame(maxHeight: .infinity)
            } else {
                Table(tableRows, selection: $selected, sortOrder: $sortOrder) {
                    TableColumn("Дата", value: \.date) { Text(CalendarDays.label($0.date)) }.width(min: 110, ideal: 120)
                    if kind == nil { TableColumn("Тип", value: \.kindTitle) { Text($0.kindTitle) }.width(115) }
                    TableColumn("Счёт", value: \.accountName) { Text($0.accountName) }
                    TableColumn("Сумма", value: \.amount) { entry in
                        let operation = entry.operation
                        VStack(alignment: .leading, spacing: 3) {
                            Text(BeeFormat.money(entry.amount, currency: entry.currency)).monospacedDigit()
                            if let to = operation.toAccountID, let received = operation.toAmount, let destination = db.accounts.first(where: { $0.id == to }) { Text("→ \(destination.name): " + BeeFormat.money(received, currency: destination.currency)).font(.caption).foregroundStyle(BeeStyle.muted) }
                        }
                    }.width(min: 155, ideal: 190)
                    TableColumn("Категория / проект") { entry in let operation = entry.operation; VStack(alignment: .leading) { Text(operation.kind.isFlow ? db.categoryPath(operation.categoryID) : "—"); if let project = db.projects.first(where: { $0.id == operation.projectID }) { Text(project.name).font(.caption).foregroundStyle(BeeStyle.muted) }; if operation.kind.isFlow, let account = db.accounts.first(where: { $0.id == operation.accountID }), account.currency != db.settings.reportCurrency, (try? Reports.rate(from: account.currency, to: db.settings.reportCurrency, rates: operation.fx, on: operation.date)) == nil { Text("Без курса \(db.settings.reportCurrency)").font(.caption).foregroundStyle(BeeStyle.warning) } } }
                    TableColumn("Комментарий", value: \.comment) { Text($0.comment).lineLimit(2) }
                }.scrollContentBackground(.hidden).background(BeeStyle.surface, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(BeeStyle.text)
                    .contextMenu(forSelectionType: UUID.self) { selection in if let id = selection.first { Button("Изменить") { edit(id) }; Button("Удалить", role: .destructive) { remove(id) } } } primaryAction: { selection in if let id = selection.first { edit(id) } }
            }
            HStack { Text("Переводы и корректировки не входят в доходы и расходы.").font(.caption).foregroundStyle(BeeStyle.backgroundMuted); Spacer(); Button("Изменить") { if let selected { edit(selected) } }.disabled(selected == nil); Button("Удалить", role: .destructive) { if let selected { remove(selected) } }.disabled(selected == nil) }
        }.padding(24).sheet(item: $editor) { route in OperationEditor(id: route.entityID, kind: route.operationKind) }
    } }
    func edit(_ id: UUID) { guard let operation = model.db?.operations.first(where: { $0.id == id }) else { return }; if operation.kind == .opening || operation.kind == .adjustment { model.error = "Начальный остаток задан при открытии. Корректировку исправляют удалением и новой сверкой." } else { editor = SheetRoute(kind: .operation, entityID: id, operationKind: operation.kind) } }
    func remove(_ id: UUID) { guard let operation = model.db?.operations.first(where: { $0.id == id }), confirmDeletion(operation.kind.title + " · " + CalendarDays.label(operation.date), consequence: "Остатки, бюджеты и отчёты пересчитаются. Для перевода удаляются обе стороны.") else { return }; model.perform { try Ledger.deleteOperation(id, in: &$0) }; selected = nil }
}

struct ReferencesView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0
    @State private var archived = false
    @State private var search = ""
    var body: some View { if let db = model.db { ScrollView { VStack(alignment: .leading, spacing: 18) {
        SectionHeading(title: "Справочники") { Button(tab == 2 ? "Новый проект" : "Новая категория", systemImage: "plus") { model.sheet = SheetRoute(kind: tab == 2 ? .project : .category, operationKind: tab == 1 ? .income : .expense) }.buttonStyle(BeePrimaryStyle()) }
        Picker("Раздел", selection: $tab) { Text("Категории расходов").tag(0); Text("Категории доходов").tag(1); Text("Проекты").tag(2) }.pickerStyle(.segmented)
        HStack { TextField("Поиск", text: $search).textFieldStyle(.roundedBorder); Toggle("Архив", isOn: $archived).toggleStyle(.checkbox) }
        VStack(alignment: .leading, spacing: 0) {
            if tab == 2 { if db.projects.isEmpty { EmptyState(title: "Проектов пока нет", detail: "Добавьте проект для отдельного учёта расходов.") }; ForEach(db.projects.filter { (archived || !$0.archived) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { project in HStack { VStack(alignment: .leading, spacing: 4) { Text(project.name + (project.archived ? " · архив" : "")).font(.headline); if !project.description.isEmpty { Text(project.description).font(.caption).foregroundStyle(BeeStyle.muted) } }; Spacer(); Menu { Button("Изменить") { model.sheet = SheetRoute(kind: .project, entityID: project.id) }; Button(project.archived ? "Вернуть" : "Архивировать") { model.perform { db in var copy = project; copy.archived.toggle(); try Ledger.saveProject(copy, in: &db) } }; Button("Удалить", role: .destructive) { if confirmDeletion(project.name, consequence: "Проект со ссылками можно только архивировать.") { model.perform { try Ledger.deleteProject(project.id, in: &$0) } } } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24) }.padding(.vertical, 14); Divider() } }
            else { ForEach(db.categories.filter { $0.kind == (tab == 0 ? .expense : .income) && (archived || !$0.archived) && (search.isEmpty || db.categoryPath($0.id).localizedCaseInsensitiveContains(search)) }.sorted { db.categoryPath($0.id) < db.categoryPath($1.id) }) { category in HStack { Image(systemName: category.parentID == nil ? "folder" : "arrow.turn.down.right").foregroundStyle(BeeStyle.muted); Text(category.name + (category.archived ? " · архив" : "")).font(category.parentID == nil ? .headline : .body); Spacer(); if !category.system { Menu { Button("Изменить") { model.sheet = SheetRoute(kind: .category, entityID: category.id) }; Button(category.archived ? "Вернуть" : "Архивировать") { model.perform { db in var copy = category; copy.archived.toggle(); try Ledger.saveCategory(copy, in: &db) } }; Button("Удалить", role: .destructive) { if confirmDeletion(category.name, consequence: "Использованную категорию можно только архивировать.") { model.perform { try Ledger.deleteCategory(category.id, in: &$0) } } } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24) } }.padding(.vertical, 14).padding(.leading, category.parentID == nil ? 0 : 20); Divider() } }
        }.beeCard()
    }.padding(26) } } }
}
