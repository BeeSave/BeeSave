import SwiftUI
import BudgetCore

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            List(SectionID.allCases, selection: $model.section) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                .navigationTitle("BeeSave").navigationSplitViewColumnWidth(min: 190, ideal: 215)
        } detail: {
            VStack(spacing: 0) {
                if let message = model.backupError { HStack { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red); Spacer(); Button("Выбрать путь") { model.changeBackupFolder() } }.padding(12).background(.red.opacity(0.08)) }
                if let notice = model.notice { HStack { Text(notice).font(.caption); Spacer(); Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(10).background(.quaternary) }
                Group {
                    switch model.section {
                    case .dashboard: DashboardView()
                    case .accounts: AccountsView()
                    case .expenses: OperationsView(kind: .expense)
                    case .incomes: OperationsView(kind: .income)
                    case .budgets: BudgetsView()
                    case .references: ReferencesView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.navigationTitle(model.section.rawValue)
            .toolbar {
                ToolbarItem { Menu { Button("Расход") { model.newOperation(.expense) }; Button("Доход") { model.newOperation(.income) }; Button("Перевод") { model.newOperation(.transfer) }; Button("Счёт") { model.sheet = SheetRoute(kind: .account) } } label: { Label("Добавить", systemImage: "plus") } }
                ToolbarItem { SettingsLink { Label("Настройки", systemImage: "gearshape") } }
                ToolbarItem { Button { model.lock() } label: { Label("Блокировка", systemImage: "lock") } }
            }
        }.sheet(isPresented: Binding(get: { model.drilldown != nil }, set: { if !$0 { model.drilldown = nil } })) { VStack { HStack { Text("Операции показателя").font(.title2.bold()); Spacer(); Button("Закрыть") { model.drilldown = nil } }.padding(); OperationsView(ids: model.drilldown) }.frame(width: 1000, height: 680) }
    }
}

struct AccountsView: View {
    @EnvironmentObject var model: AppModel; @State private var archived = true
    var body: some View { if let db = model.db {
        if let id = model.historyAccount, let a = db.accounts.first(where: { $0.id == id }) {
            VStack(alignment: .leading) { HStack { Button("Все счета", systemImage: "chevron.left") { model.historyAccount = nil }; Text(a.name).font(.title2.bold()); Spacer(); Button("Сверить остаток") { model.sheet = SheetRoute(kind: .reconciliation, entityID: id) }.disabled(a.archived) }.padding(); OperationsView(accountID: id) }
        } else {
            ScrollView { VStack(alignment: .leading, spacing: 18) {
                HStack { Text("Счета и остатки").font(.largeTitle.bold()); Spacer(); Toggle("Показать архив", isOn: $archived); Button("Новый счёт", systemImage: "plus") { model.sheet = SheetRoute(kind: .account) } }
                if db.accounts.isEmpty { EmptyState(title: "Добавьте первый счёт", detail: "Укажите валюту и начальный остаток. Бюджет для начала работы не требуется.", icon: "wallet.bifold") }
                ForEach(db.accounts.filter { archived || !$0.archived }) { a in
                    let balance = (try? db.balance(a.id)) ?? 0
                    HStack(spacing: 18) {
                        Image(systemName: a.archived ? "archivebox" : "creditcard").font(.title).foregroundStyle(.teal)
                        VStack(alignment: .leading) { Text(a.name).font(.headline); Text("\(a.currency) · с \(a.openedOn.rawValue)\(a.archived ? " · архив" : "")").foregroundStyle(.secondary) }
                        Spacer(); VStack(alignment: .trailing) { Text(Money.display(balance, currency: a.currency)).font(.title2.monospacedDigit()).foregroundStyle(balance < 0 ? .red : .primary); if balance < 0 { Text("Отрицательный остаток").font(.caption).foregroundStyle(.red) } }
                        Button("История") { model.openHistory(a.id) }
                        Menu { Button("Изменить") { model.sheet = SheetRoute(kind: .account, entityID: a.id) }; Button("Сверить") { model.sheet = SheetRoute(kind: .reconciliation, entityID: a.id) }.disabled(a.archived)
                            Button(a.archived ? "Вернуть из архива" : "Архивировать") { if a.archived || confirmDeletion(a.name, consequence: "Архивирование сохраняет историю и остаток \(Money.display(balance, currency: a.currency)). Новые операции будут недоступны.") { model.perform { db in var copy = a; copy.archived.toggle(); try Ledger.saveAccount(copy, in: &db) } } }
                            Button("Удалить", role: .destructive) { if confirmDeletion(a.name, consequence: "Удаляется только пустой счёт без ссылок. Для счёта с историей используйте архив.") { model.perform { try Ledger.deleteAccount(a.id, in: &$0) } } }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28)
                    }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
                }
            }.padding(24) }
        }
    } }
}

struct OperationsView: View {
    @EnvironmentObject var model: AppModel; var kind: OperationKind?; var accountID: UUID?; var ids: [UUID]?
    @State private var filters = Filters(); @State private var selected: UUID?
    var operations: [BudgetCore.Operation] { guard let db = model.db else { return [] }; var f = filters; if let accountID { f.accounts = [accountID] }; let result = Reports.selected(db, filters: f, kinds: kind.map { [$0] }); if let ids { let set = Set(ids); return result.filter { set.contains($0.id) } }; return result }
    var body: some View { if let db = model.db { VStack(alignment: .leading, spacing: 14) {
        HStack { Text(ids != nil ? "Детализация · \(operations.count) записей" : (kind == .expense ? "Расходы" : kind == .income ? "Доходы" : "История счёта")).font(.title2.bold()); Spacer(); Button("Экспорт выборки") { model.exportCSV(selection: operations) }; if let kind { Button("Добавить", systemImage: "plus") { model.newOperation(kind) } } }
        FilterBar(filters: $filters)
        HStack { TextField("Поиск по комментарию", text: $filters.search).textFieldStyle(.roundedBorder); Toggle("Сначала новые", isOn: $filters.newestFirst).toggleStyle(.checkbox) }
        if operations.isEmpty { EmptyState(title: db.operations.isEmpty ? "Операций пока нет" : "Нет совпадений", detail: "Добавьте операцию или измените фильтры.") }
        else { Table(operations, selection: $selected) {
            TableColumn("Дата") { Text($0.date.rawValue) }.width(100)
            TableColumn("Тип") { Text($0.kind.title) }.width(120)
            TableColumn("Счёт") { o in Text(db.accounts.first { $0.id == o.accountID }?.name ?? "—") }
            TableColumn("Сумма") { o in let a = db.accounts.first { $0.id == (accountID ?? o.accountID) }; VStack(alignment: .leading) { Text(Money.display(accountID.map { o.posting(for: $0) } ?? o.amount, currency: a?.currency ?? "RUB")).monospacedDigit(); if let to = o.toAccountID, let received = o.toAmount, let b = db.accounts.first(where: { $0.id == to }) { Text("→ " + Money.display(received, currency: b.currency)).font(.caption) } } }.width(min: 150, ideal: 170)
            TableColumn("Категория / проект") { o in VStack(alignment: .leading) { Text(o.kind.isFlow ? db.categoryPath(o.categoryID) : "—"); if let p = db.projects.first(where: { $0.id == o.projectID }) { Text(p.name).font(.caption).foregroundStyle(.secondary) }; if o.kind.isFlow, let a = db.accounts.first(where: { $0.id == o.accountID }), a.currency != db.settings.reportCurrency, (try? Reports.rate(from: a.currency, to: db.settings.reportCurrency, rates: o.fx, on: o.date)) == nil { Text("Не хватает курса").font(.caption).foregroundStyle(.orange) } } }
            TableColumn("Комментарий") { Text($0.comment).lineLimit(2) }
        }.contextMenu(forSelectionType: UUID.self) { selection in if let id = selection.first { Button("Изменить") { edit(id) }; Button("Удалить", role: .destructive) { remove(id) } } } primaryAction: { selection in if let id = selection.first { edit(id) } }
        }
        HStack { Text("Начальные остатки, переводы и корректировки не входят в доходы/расходы.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Изменить") { if let selected { edit(selected) } }.disabled(selected == nil); Button("Удалить", role: .destructive) { if let selected { remove(selected) } }.disabled(selected == nil) }
    }.padding(22) } }
    func edit(_ id: UUID) { guard let o = model.db?.operations.first(where: { $0.id == id }) else { return }; if o.kind == .opening || o.kind == .adjustment { model.error = "Начальный остаток задан при открытии. Корректировку исправляют удалением и новой сверкой." } else { model.sheet = SheetRoute(kind: .operation, entityID: id, operationKind: o.kind) } }
    func remove(_ id: UUID) { guard let o = model.db?.operations.first(where: { $0.id == id }), confirmDeletion(o.kind.title + " " + o.date.rawValue, consequence: "Операция будет удалена. Остатки, бюджеты и отчёты пересчитаются; для перевода удаляются обе стороны.") else { return }; model.perform { try Ledger.deleteOperation(id, in: &$0) }; selected = nil }
}

struct ReferencesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { if let db = model.db { ScrollView { VStack(alignment: .leading, spacing: 22) {
        HStack { Text("Категории").font(.title2.bold()); Spacer(); Button("Новая категория") { model.sheet = SheetRoute(kind: .category) } }
        ForEach([OperationKind.expense, .income], id: \.self) { kind in GroupBox(kind == .expense ? "Расходы" : "Доходы") { ForEach(db.categories.filter { $0.kind == kind }.sorted { db.categoryPath($0.id) < db.categoryPath($1.id) }) { c in HStack { Text(db.categoryPath(c.id) + (c.archived ? " · архив" : "")); Spacer(); if !c.system { Button("Изменить") { model.sheet = SheetRoute(kind: .category, entityID: c.id) }; Button(c.archived ? "Вернуть" : "Архив") { model.perform { db in var copy = c; copy.archived.toggle(); try Ledger.saveCategory(copy, in: &db) } }; Button("Удалить", role: .destructive) { if confirmDeletion(c.name, consequence: "Использованную категорию можно только архивировать.") { model.perform { try Ledger.deleteCategory(c.id, in: &$0) } } } } }.padding(8) } } }
        HStack { Text("Проекты").font(.title2.bold()); Spacer(); Button("Новый проект") { model.sheet = SheetRoute(kind: .project) } }
        if db.projects.isEmpty { EmptyState(title: "Проектов нет", detail: "Проект необязателен. Добавьте его для отдельного учёта расходов.") }
        ForEach(db.projects) { p in HStack { VStack(alignment: .leading) { Text(p.name + (p.archived ? " · архив" : "")).font(.headline); Text(p.description).foregroundStyle(.secondary) }; Spacer(); Button("Изменить") { model.sheet = SheetRoute(kind: .project, entityID: p.id) }; Button(p.archived ? "Вернуть" : "Архив") { model.perform { db in var copy = p; copy.archived.toggle(); try Ledger.saveProject(copy, in: &db) } }; Button("Удалить", role: .destructive) { if confirmDeletion(p.name, consequence: "Проект со ссылками можно только архивировать.") { model.perform { try Ledger.deleteProject(p.id, in: &$0) } } } }.padding(14) }
    }.padding(24) } } }
}
