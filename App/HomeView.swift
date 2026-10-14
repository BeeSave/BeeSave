import SwiftUI
import BudgetCore
import BudgetPresentation

struct HomeView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.beeAppearance) private var appearance
    var body: some View {
        NavigationSplitView {
            BeeSidebar(items: SectionID.allCases, selection: $model.section, name: "Боковое меню") { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.icon).frame(width: 26 * appearance.scale).accessibilityHidden(true)
                        Text(item.rawValue).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }.beeFont(.body).padding(.vertical, 5)
            }
                .clipped()
                .navigationSplitViewColumnWidth(min: 210 + 140 * (appearance.scale - 1), ideal: 240 + 120 * (appearance.scale - 1), max: 360)
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        SettingsLink { Label("Настройки", systemImage: "gearshape") }
                        Spacer()
                        Button { model.lock() } label: { Image(systemName: "lock") }
                            .help("Заблокировать бюджет · ⇧⌘L").accessibilityLabel("Заблокировать бюджет")
                    }.buttonStyle(.borderless).beeFont(.caption).padding(16)
                }
        } detail: {
            VStack(spacing: 0) {
                if model.navigation.canGoBack {
                    HStack {
                        Button(model.backDestinationTitle, systemImage: "chevron.left") { model.navigateBack() }
                            .help("Вернуться к исходной странице с её фильтрами")
                        Spacer()
                    }.beeFont(.caption).padding(.horizontal, 26).padding(.top, 12)
                }
                if let message = model.backupError { HStack { Label(message, systemImage: "exclamationmark.triangle.fill"); Spacer(); Button("Выбрать папку") { model.changeBackupFolder() } }.beeFont(.caption).padding(12).foregroundStyle(BeeStyle.negative).background(BeeStyle.surface) }
                switch model.navigation.current.section {
                case .overview: DashboardView()
                case .accounts: AccountsView()
                case .plan: PlanningView()
                case .projects: ProjectsView()
                case .operations: OperationsWorkspace()
                }
            }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).beeNavigationContent().navigationTitle(model.section.rawValue).environment(\.beeToolbarActions, true)

        }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .toolbarBackground(BeeStyle.background, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .sheet(isPresented: Binding(get: { model.drilldown != nil }, set: { if !$0 { model.drilldown = nil } })) {
            VStack(spacing: 0) { HStack { Text(model.drilldownTitle).beeFont(.title2.bold()); Spacer(); Button("Закрыть") { model.drilldown = nil }.keyboardShortcut(.cancelAction) }.padding(22); OperationsView(ids: model.drilldown, initialFilters: model.drilldownFilters, valuationCurrency: model.drilldownCurrency) }.beeSheet(width: 960, height: 640).beeWindow()
        }
    }
}

struct AccountsView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    private var route: WorkspaceRoute { WorkspaceRoute(.accounts) }
    private var archived: Binding<Bool> { Binding(get: { model.navigation.context(for: route).archived }, set: { value in model.updateWorkspaceContext(route) { $0.archived = value } }) }
    private var financialKind: Binding<AccountKind?> { Binding(get: { model.navigation.context(for: route).accountKind }, set: { value in model.updateWorkspaceContext(route) { $0.accountKind = value } }) }
    private var accountSearch: Binding<String> { Binding(get: { model.navigation.context(for: route).search }, set: { value in model.updateWorkspaceContext(route) { $0.search = value } }) }
    var body: some View { if let db = model.db {
        if let id = model.historyAccount, let account = db.accounts.first(where: { $0.id == id }) {
            if account.kind == .ordinary {
                VStack(alignment: .leading, spacing: 14) {
                    historyHeader(account, db: db)
                    OperationsView(accountID: id, workspaceRoute: WorkspaceRoute(.accounts, objectID: id))
                }
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            historyHeader(account, db: db)
                            FinancialAccountDetail(accountID: id)
                            OperationsView(accountID: id, workspaceRoute: WorkspaceRoute(.accounts, objectID: id))
                                .frame(height: max(420 * appearanceStore.preferences.scale, geometry.size.height - 320 * appearanceStore.preferences.scale))
                        }
                    }
                }
            }
        } else { ScrollView { LazyVStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: "Счета") { Button("Новый счёт", systemImage: "plus") { model.sheet = SheetRoute(kind: .account) }.buttonStyle(BeePrimaryStyle()) }
            BeeSegments(title: "Список счетов", labels: ["Активные", "Архив"], selection: Binding(get: { archived.wrappedValue ? 1 : 0 }, set: { archived.wrappedValue = $0 == 1 }))
                .frame(maxWidth: 560 * pow(appearanceStore.preferences.scale, 0.5)).frame(maxWidth: .infinity)
            BeePicker("Тип счёта", selection: financialKind) { Text("Все типы").tag(nil as AccountKind?); ForEach(AccountKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) } }.frame(maxWidth: 300 * appearanceStore.preferences.scale)
            VStack(alignment:.leading,spacing:12) {
                TextField("Найти счёт, банк или валюту",text:accountSearch).textFieldStyle(BeeTextFieldStyle())
                WrappingLayout(spacing:12) { BeeSegments(title:"Вид счетов",labels:["Список","Карточки"],selection:Binding(get:{ db.planningData.accountCards ? 1 : 0 },set:{ model.changePlanning(.accountView($0 == 1,db.planningData.accountSort)) })).frame(width:240 * appearanceStore.preferences.scale)
                BeePicker("Сортировка",selection:Binding(get:{ db.planningData.accountSort },set:{ model.changePlanning(.accountView(db.planningData.accountCards,$0)) })) { Text("Название").tag("name"); Text("Валюта").tag("currency"); Text("Остаток").tag("balance") }.labelsHidden().frame(width:180 * appearanceStore.preferences.scale) }
            }
            let visible = db.accounts.filter { $0.archived == archived.wrappedValue && (financialKind.wrappedValue == nil || $0.kind == financialKind.wrappedValue) && (accountSearch.wrappedValue.isEmpty || ($0.name + " " + $0.currency + " " + (db.financialBankName($0.bankID) ?? $0.bankID ?? "")).localizedCaseInsensitiveContains(accountSearch.wrappedValue)) }.sorted { lhs,rhs in
                if db.planningData.accountSort == "currency",lhs.currency != rhs.currency { return lhs.currency < rhs.currency }
                if db.planningData.accountSort == "balance" && lhs.currency != rhs.currency { return lhs.currency < rhs.currency }
                if db.planningData.accountSort == "balance" { let a = (try? db.balance(lhs.id)) ?? 0,b = (try? db.balance(rhs.id)) ?? 0; if a != b { return a > b } }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            if visible.isEmpty {
                EmptyState(title: archived.wrappedValue ? "В архиве пока нет счетов" : db.accounts.isEmpty ? "Добавьте первый счёт" : "Нет активных счетов",
                           detail: archived.wrappedValue ? "Архивные счета сохраняют свою историю. Их можно вернуть в активные." : db.accounts.isEmpty ? "Карта, накопления или наличные — валюта и начальный остаток." : "Выберите другой тип счёта или добавьте новый.", icon: archived.wrappedValue ? "archivebox" : "wallet.bifold").beeCard()
            }
            ForEach(FinancialAccountSection.allCases) { section in
                let accounts = visible.filter { section.includes($0.kind) }
                if !accounts.isEmpty {
                    Text(section.rawValue).beeFont(.headline).foregroundStyle(BeeStyle.backgroundMuted)
                    if db.planningData.accountCards {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:300 * appearanceStore.preferences.scale,maximum:500 * appearanceStore.preferences.scale))],spacing:18) { ForEach(accounts) { account in AccountPlanningCard(account:account,db:db) } }
                    } else { LazyVStack(spacing: 0) { ForEach(accounts) { account in FinancialAccountRow(account: account, db: db); if account.id != accounts.last?.id { Divider() } } }.beeCard() }
                }
            }
        }.padding(26).background(WorkspaceScrollMemory(route: route)) } }
    } }
    private func historyHeader(_ account: Account, db: Database) -> some View {
        VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack { historyBack; Text(account.name).beeFont(.title2.bold()).fixedSize(); Spacer(); Text(historyBalance(account, db: db)).beeFont(.title2).monospacedDigit().fixedSize() }
                    VStack(alignment: .leading, spacing: 10) { historyBack; Text(account.name).beeFont(.title2.bold()); Text(historyBalance(account, db: db)).beeFont(.title2).monospacedDigit() }
                }.padding(.horizontal, 24).padding(.top, 20)
                HStack {
                    if account.archived { Label("Счёт в архиве", systemImage: "archivebox"); Button("Вернуть из архива") { model.perform { db in var copy = account; copy.archived = false; try Ledger.saveAccount(copy, in: &db) } } }
                    else {
                        ViewThatFits(in: .horizontal) {
                            HStack { historyCommands(account.id).fixedSize() }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190 * appearanceStore.preferences.scale), alignment: .leading)], alignment: .leading, spacing: 10) { historyCommands(account.id).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }.padding(.horizontal, 24)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var historyBack: some View { Button("Все счета", systemImage: "chevron.left") { model.historyAccount = nil } }
    @ViewBuilder private func historyCommands(_ id: UUID) -> some View {
        Button("Добавить расход") { model.newOperation(.expense, account: id) }.buttonStyle(BeePrimaryStyle())
        Button("Добавить доход") { model.newOperation(.income, account: id) }
        Button("Перевести") { model.newOperation(.transfer, account: id) }
        Button("Сверить остаток") { model.sheet = SheetRoute(kind: .reconciliation, entityID: id) }
    }
    private func historyBalance(_ account: Account, db: Database) -> String {
        let balance = (try? db.balance(account.id)) ?? 0
        return (account.kind.isDebt && balance < 0 ? "Долг: " : "") + BeeFormat.money(account.kind.isDebt && balance < 0 ? -balance : balance, currency: account.currency)
    }

}

struct OperationsView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var kind: OperationKind?
    var workspaceRoute: WorkspaceRoute? = nil
    var accountID: UUID?
    var ids: [UUID]?
    var valuationCurrency: String?
    var initialPeriod: Filters
    @State private var filters: Filters
    @State private var selected: UUID?
    @State private var editor: SheetRoute?
    @State private var sortOrder = [KeyPathComparator(\OperationTableEntry.date, order: .reverse)]
    init(kind: OperationKind? = nil, accountID: UUID? = nil, ids: [UUID]? = nil, initialFilters: Filters = Filters(), valuationCurrency: String? = nil, workspaceRoute: WorkspaceRoute? = nil) { self.valuationCurrency = valuationCurrency; self.kind = kind; self.accountID = accountID; self.ids = ids; self.initialPeriod = initialFilters; self.workspaceRoute = workspaceRoute; _filters = State(initialValue: initialFilters) }
    var operations: [BudgetCore.Operation] { guard let db = model.db else { return [] }; var candidate = filters; if let accountID { candidate.accounts = [accountID] }; var rows = Reports.selected(db, filters: candidate, kinds: kind.map { [$0] }, sorted: false); if let ids { let allowed = Set(ids); rows = rows.filter { allowed.contains($0.id) } }; return rows }
    private var tableRows: [OperationTableEntry] { guard let db = model.db else { return [] }; let accounts = Dictionary(uniqueKeysWithValues: db.accounts.map { ($0.id, $0) }); return operations.map { OperationTableEntry(operation: $0, source: accounts[$0.accountID], context: accountID.flatMap { accounts[$0] }) }.sorted(using: sortOrder) }
    private var exportFilters: Filters { var value = filters; if let accountID { value.accounts = [accountID] }; return value }
    var body: some View { if let db = model.db {
        GeometryReader { geometry in
            if geometry.size.height < 560 * appearanceStore.preferences.scale {
                ScrollView {
                    operationsContent(db).frame(height: max(760 * appearanceStore.preferences.scale, geometry.size.height))
                        .background { if let workspaceRoute { WorkspaceScrollMemory(route: workspaceRoute) } }
                }
            } else { operationsContent(db) }
        }
    } }
    private func operationsContent(_ db: Database) -> some View {
        let reportCurrency = valuationCurrency ?? db.settings.reportCurrency
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: ids != nil ? "Детализация" : workspaceRoute?.section == .operations ? "Журнал операций" : accountID != nil ? (db.accounts.first { $0.id == accountID }?.name ?? "История счёта") : kind == .expense ? "Расходы" : kind == .income ? "Доходы" : "История") {
                Button("Экспорт…") { model.exportCSV(selection: operations, filters: exportFilters) }
                if kind == .expense { Button("Запланировать расход") { model.sheet = SheetRoute(kind: .scheduledPayment) } }
                if let kind, kind.isFlow { Button(kind == .expense ? "Добавить расход" : "Добавить доход", systemImage: "plus") { model.newOperation(kind) }.buttonStyle(BeePrimaryStyle()) }
                else if workspaceRoute?.section == .operations { Menu("Добавить", systemImage: "plus") { Button("Расход") { model.newOperation(.expense) }; Button("Доход") { model.newOperation(.income) }; Button("Перевод") { model.newOperation(.transfer) } } }
            }
            FilterBar(filters: $filters, showParticipation: kind != .income, kind: kind, fixedAccount: accountID, operationIDs: ids, resetPeriod: initialPeriod)
            HStack { TextField("Поиск по комментарию", text: $filters.search).textFieldStyle(BeeTextFieldStyle()); Text("\(operations.count) записей").beeFont(.caption).foregroundStyle(BeeStyle.backgroundMuted) }
            if operations.isEmpty {
                VStack { EmptyState(title: db.operations.contains(where: { $0.kind.isFlow }) ? "Нет совпадений" : "Операций пока нет", detail: "Добавьте операцию или измените выборку."); Button("Сбросить фильтры") { filters = Filters() } }.beeCard().frame(maxHeight: .infinity)
            } else {
                Table(tableRows, selection: $selected, sortOrder: $sortOrder) {
                    TableColumn("Дата", value: \.date) { Text(CalendarDays.label($0.date)) }.width(min: 110 * appearanceStore.preferences.scale, ideal: 120 * appearanceStore.preferences.scale)
                    if kind == nil { TableColumn("Тип", value: \.kindTitle) { Text($0.kindTitle) }.width(115 * appearanceStore.preferences.scale) }
                    TableColumn("Счёт", value: \.accountName) { Text($0.accountName) }.width(min: 130 * appearanceStore.preferences.scale, ideal: 170 * appearanceStore.preferences.scale)
                    TableColumn("Сумма", value: \.amount) { entry in
                        let operation = entry.operation
                        VStack(alignment: .leading, spacing: 3) {
                            Text(BeeFormat.money(entry.amount, currency: entry.currency)).monospacedDigit()
                            if let to = operation.toAccountID, let received = operation.toAmount, let destination = db.accounts.first(where: { $0.id == to }) { Text("→ \(destination.name): " + BeeFormat.money(received, currency: destination.currency)).beeFont(.caption).foregroundStyle(BeeStyle.muted) }
                        }
                    }.width(min: 155 * appearanceStore.preferences.scale, ideal: 190 * appearanceStore.preferences.scale)
                    TableColumn("Категория / проект") { entry in let operation = entry.operation; VStack(alignment: .leading) { Text(operation.kind.isFlow ? db.categoryPath(operation.categoryID) : "—"); if let project = db.projects.first(where: { $0.id == operation.projectID }) { Text(project.name).beeFont(.caption).foregroundStyle(BeeStyle.muted) }; if operation.kind.isFlow, let account = db.accounts.first(where: { $0.id == operation.accountID }), account.currency != reportCurrency, (try? Reports.rate(from: account.currency, to: reportCurrency, rates: operation.fx, on: operation.date)) == nil { Text("Без курса \(reportCurrency)").beeFont(.caption).foregroundStyle(BeeStyle.warning) } } }.width(min: 180 * appearanceStore.preferences.scale, ideal: 230 * appearanceStore.preferences.scale)
                    TableColumn("Комментарий", value: \.comment) { Text($0.comment).lineLimit(2) }.width(min: 140 * appearanceStore.preferences.scale, ideal: 220 * appearanceStore.preferences.scale)
                }.scrollContentBackground(.hidden).foregroundStyle(BeeStyle.text)
                    .contextMenu(forSelectionType: UUID.self) { selection in if let id = selection.first { Button("Изменить") { edit(id) }; ForEach((db.financeData.scheduledPayments ?? []).filter { $0.allocations.contains { $0.operationID == id } }) { p in Button("План: " + p.title) { openScheduled(p.id) } }; Button("Удалить", role: .destructive) { remove(id) } } } primaryAction: { selection in if let id = selection.first { edit(id) } }
                .frame(minHeight: 180, maxHeight: .infinity)
                .background { if let workspaceRoute { WorkspaceScrollMemory(route: workspaceRoute, table: true) } }
                .background(BeeStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            ViewThatFits(in: .horizontal) {
                HStack { tableHint; Spacer(); selectionActions }
                VStack(alignment: .leading, spacing: 10) { tableHint; HStack { Spacer(); selectionActions } }
            }
        }.padding(24).sheet(item: $editor) { route in OperationEditor(id: route.entityID, kind: route.operationKind) }
        .onAppear { if let workspaceRoute { let memory = model.navigation.context(for: workspaceRoute); filters = memory.filters; selected = memory.selectedID; if let id = selected, !operations.contains(where: { $0.id == id }) { selected = nil } } }
        .onChange(of: filters) { _, value in if let workspaceRoute { model.updateWorkspaceContext(workspaceRoute) { $0.filters = value } } }
        .onChange(of: selected) { _, value in if let workspaceRoute { model.updateWorkspaceContext(workspaceRoute) { $0.selectedID = value } } }
    }
    private var tableHint: some View { Text("Переводы и корректировки не входят в доходы и расходы.").beeFont(.caption).foregroundStyle(BeeStyle.backgroundMuted).fixedSize(horizontal: false, vertical: true) }
    private var selectionActions: some View { HStack { Button("Изменить") { if let selected { edit(selected) } }.disabled(selected == nil); Button("Удалить", role: .destructive) { if let selected { remove(selected) } }.disabled(selected == nil) } }
    private func openScheduled(_ id: UUID) { model.sheet = nil; model.drilldown = nil; DispatchQueue.main.async { model.sheet = SheetRoute(kind: .scheduledDetail, entityID: id) } }
    func edit(_ id: UUID) { guard let operation = model.db?.operations.first(where: { $0.id == id }) else { return }; if operation.kind == .opening || operation.kind == .adjustment { model.error = "Начальный остаток задан при открытии. Корректировку исправляют удалением и новой сверкой." } else if let group = operation.financial?.groupID { model.sheet = SheetRoute(kind: .financialPayment, entityID: group) } else { editor = SheetRoute(kind: .operation, entityID: id, operationKind: operation.kind) } }
    func remove(_ id: UUID) { guard let operation = model.db?.operations.first(where: { $0.id == id }), confirmDeletion(operation.kind.title + " · " + CalendarDays.label(operation.date), consequence: "Остатки, бюджеты и отчёты пересчитаются. Финансовый платёж удаляется целой группой. Для перевода удаляются обе стороны.") else { return }; model.perform { try Ledger.deleteOperation(id, in: &$0) }; selected = nil }
}

struct ReferencesView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    private let route = WorkspaceRoute(.operations, operations: .references)
    private var tab: Binding<Int> { Binding(get: { model.navigation.context(for: route).referencePage }, set: { value in model.updateWorkspaceContext(route) { $0.referencePage = value } }) }
    private var archived: Binding<Bool> { Binding(get: { model.navigation.context(for: route).archived }, set: { value in model.updateWorkspaceContext(route) { $0.archived = value } }) }
    private var search: Binding<String> { Binding(get: { model.navigation.context(for: route).search }, set: { value in model.updateWorkspaceContext(route) { $0.search = value } }) }
    var body: some View { if let db = model.db { ScrollView { VStack(alignment: .leading, spacing: 18) {
        SectionHeading(title: "Справочники") { if tab.wrappedValue != 2 { Button(tab.wrappedValue == 3 ? "Новый банк" : "Новая категория", systemImage: "plus") { model.sheet = SheetRoute(kind: tab.wrappedValue == 3 ? .bank : .category, operationKind: tab.wrappedValue == 1 ? .income : .expense) }.buttonStyle(BeePrimaryStyle()) } }
        BeePicker("Раздел", selection: tab) { Text("Категории расходов").tag(0); Text("Категории доходов").tag(1); Text("Проекты").tag(2); Text("Банки").tag(3) }.beePickerStyle(.segmented)
        HStack { TextField("Поиск", text: search).textFieldStyle(BeeTextFieldStyle()); Toggle("Архив", isOn: archived).toggleStyle(.checkbox) }
        VStack(alignment: .leading, spacing: 0) {
            if tab.wrappedValue == 3 { BankReferenceList(search: search.wrappedValue, archived: archived.wrappedValue) }
            else if tab.wrappedValue == 2 { VStack(alignment: .leading, spacing: 12) { Text("Управление проектами находится в отдельном разделе."); Button("Открыть проекты", systemImage: "flag") { model.navigate(WorkspaceRoute(.projects)) }.buttonStyle(BeePrimaryStyle()) } }
            else { ForEach(db.categories.filter { $0.kind == (tab.wrappedValue == 0 ? .expense : .income) && (archived.wrappedValue || !$0.archived) && (search.wrappedValue.isEmpty || db.categoryPath($0.id).localizedCaseInsensitiveContains(search.wrappedValue)) }.sorted { db.categoryPath($0.id) < db.categoryPath($1.id) }) { category in HStack { Image(systemName: category.parentID == nil ? "folder" : "arrow.turn.down.right").foregroundStyle(BeeStyle.muted); Text(category.name + (category.archived ? " · архив" : "")).beeFont(category.parentID == nil ? .headline : .body); Spacer(); if !category.system { Menu { Button("Изменить") { model.sheet = SheetRoute(kind: .category, entityID: category.id) }; Button(category.archived ? "Вернуть" : "Архивировать") { model.perform { db in var copy = category; copy.archived.toggle(); try Ledger.saveCategory(copy, in: &db) } }; Button("Удалить", role: .destructive) { if confirmDeletion(category.name, consequence: "Использованную категорию можно только архивировать.") { model.perform { try Ledger.deleteCategory(category.id, in: &$0) } } } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28) } }.padding(.vertical, 14).padding(.leading, category.parentID == nil ? 0 : 20); Divider() } }
        }.beeCard()
    }.padding(26).background(WorkspaceScrollMemory(route: route)) } } }
}
