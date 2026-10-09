import SwiftUI
import Charts
import BudgetCore
import BudgetPresentation

func dashboardTitle(_ block: DashboardBlock, db: Database?) -> String {
    switch block.kind { case "balances": "Всего на счетах"; case "flows": "За выбранный период"; case "trend": "Доходы и расходы"; case "categories": "Расходы по категориям"; case "monthly": "Месячный бюджет"; case "projects": "Проекты"; case "outside": "Вне бюджетов"; default: db?.reports.first { $0.id == block.reportID }?.name ?? "Отчёт" }
}

struct DashboardView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.beeAppearance) private var appearance
    @State private var availableWidth: CGFloat = 950
    var filters: Binding<Filters> { Binding(get: { model.db?.settings.dashboardFilters ?? .month }, set: { f in model.perform { $0.settings.dashboardFilters = f } }) }
    var currency: Binding<String> { Binding(get: { model.db?.settings.reportCurrency ?? "RUB" }, set: { c in model.perform { $0.settings.reportCurrency = c } }) }
    var gridRows: [[DashboardBlock]] {
        var result: [[DashboardBlock]] = []; var pending: [DashboardBlock] = []
        for block in model.db?.dashboard.filter(\.visible) ?? [] {
            let budget = ["monthly", "projects", "outside"].contains(block.kind)
            if block.wide { if !pending.isEmpty { result.append(pending); pending = [] }; result.append([block]) }
            else {
                if !pending.isEmpty && budget != ["monthly", "projects", "outside"].contains(pending[0].kind) { result.append(pending); pending = [] }
                pending.append(block); if pending.count == (budget ? 3 : 2) { result.append(pending); pending = [] }
            }
        }
        if !pending.isEmpty { result.append(pending) }
        let count = max(1, Int((availableWidth - 52 + 18) / (320 * appearance.scale + 18)))
        let rows = result.flatMap { row in stride(from: 0, to: row.count, by: count).map { Array(row[$0..<min(row.count, $0 + count)]) } }
        // Keep the balance columns together as text grows, preserving the saved layout order.
        return rows.flatMap { row -> [[DashboardBlock]] in
            let cardWidth = (availableWidth - 52 - CGFloat(row.count - 1) * 18) / CGFloat(row.count)
            if row.count > 1, row.contains(where: { $0.kind == "balances" }), cardWidth < 402 * appearance.scale + 40 {
                return row.map { [$0] }
            }
            return [row]
        }
    }
    var body: some View { if let db = model.db { ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            SectionHeading(title: model.showGettingStarted ? "Начнём учёт" : "Главная") {
                if !db.accounts.isEmpty && !model.showGettingStarted {
                Button("Добавить расход", systemImage: "plus") { model.newOperation(.expense) }.buttonStyle(BeePrimaryStyle())
                Menu { Button("Добавить доход") { model.newOperation(.income) }; Button("Перевести между счетами") { model.newOperation(.transfer) } } label: { Image(systemName: "chevron.down") }.menuIndicator(.hidden)
                Menu("Отчёты") { ForEach(db.reports) { report in Button(report.name) { model.sheet = SheetRoute(kind: .reportView, entityID: report.id) } }; Divider(); Button("Создать отчёт…") { model.sheet = SheetRoute(kind: .report) } }
                Button("Настроить", systemImage: "rectangle.3.group") { model.sheet = SheetRoute(kind: .layout) }
                }
            }
            DashboardExchangeRates()
            if !db.accounts.isEmpty && !model.showGettingStarted {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) { FilterBar(filters: filters, kinds: [.expense, .income]); CurrencyPicker(title: "Валюта", selection: currency, compact: true).fixedSize() }
                    VStack(alignment: .leading, spacing: 12) { FilterBar(filters: filters, kinds: [.expense, .income]); CurrencyPicker(title: "Валюта", selection: currency, compact: true) }
                }
            }
            FinancialDashboardSummary()
            ScheduledDashboardSummary()
            if db.accounts.isEmpty || model.showGettingStarted {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "wallet.bifold").beeFont(.system(size: 32)).foregroundStyle(BeeStyle.expense)
                    Text("Добавьте первый счёт").beeFont(.title.bold()); Text("Начните с карты или наличных: задайте валюту и текущий остаток.").foregroundStyle(BeeStyle.muted)
                    HStack { Button("Создать счёт", systemImage: "plus") { model.showGettingStarted = false; model.sheet = SheetRoute(kind: .account) }.buttonStyle(BeePrimaryStyle()); Button("Импортировать CSV") { model.showGettingStarted = false; model.sheet = SheetRoute(kind: .importCSV) }; if model.showGettingStarted { Button("Позже") { model.showGettingStarted = false } } }
                }.frame(maxWidth: .infinity, alignment: .leading).beeCard(padding: 28)
            } else if !db.operations.contains(where: { $0.kind.isFlow }) {
                DashboardBlockView(block: db.dashboard.first(where: { $0.kind == "balances" }) ?? DashboardBlock(kind: "balances"))
                VStack(alignment: .leading, spacing: 16) { Text("Добавьте первый расход или доход").beeFont(.title2.bold()); Text("Остатки уже доступны. Сводка потоков появится после первой операции.").foregroundStyle(BeeStyle.muted); HStack { Button("Добавить расход") { model.newOperation(.expense) }.buttonStyle(BeePrimaryStyle()); Button("Добавить доход") { model.newOperation(.income) } } }.frame(maxWidth: .infinity, alignment: .leading).beeCard()
            } else {
                Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                    ForEach(Array(gridRows.enumerated()), id: \.offset) { _, row in GridRow(alignment: .top) { ForEach(row) { block in DashboardBlockView(block: block).frame(maxWidth: .infinity, alignment: .topLeading).gridCellColumns(6 / row.count) } } }
                }
                if Reports.selected(db, filters: db.settings.dashboardFilters, kinds: [.income, .expense]).isEmpty { HStack { Text("В этой выборке нет потоковых операций."); Spacer(); Button("Сбросить фильтры") { filters.wrappedValue = .month } }.beeCard() }
            }
        }.padding(26)
    }.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 } } }
}

struct DashboardBlockView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var block: DashboardBlock
    @State private var ownOpen = false
    @State private var own = Filters.month
    var body: some View { if let db = model.db {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(dashboardTitle(block, db: db)).beeFont(.headline); Spacer(); Menu {
                Button("Собственные фильтры…") { own = block.ownFilters ?? db.settings.dashboardFilters; ownOpen = true }
                if block.ownFilters != nil { Button("Использовать общие фильтры") { model.perform { db in if let index = db.dashboard.firstIndex(where: { $0.id == block.id }) { db.dashboard[index].ownFilters = nil } } } }
                if let id = block.reportID { Button("Открыть отчёт") { model.sheet = SheetRoute(kind: .reportView, entityID: id) } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(BeeStyle.muted).frame(width: 28)
                .popover(isPresented: $ownOpen) { VStack(alignment: .leading, spacing: 14) { Text("Фильтры блока").beeFont(.headline); FilterBar(filters: $own); HStack { Button("Отмена") { ownOpen = false }.keyboardShortcut(.cancelAction); Button("Сохранить") { model.perform { db in if let index = db.dashboard.firstIndex(where: { $0.id == block.id }) { db.dashboard[index].ownFilters = own } }; ownOpen = false }.buttonStyle(BeePrimaryStyle()) } }.padding(20).frame(width: 400).foregroundStyle(.primary) }
            }
            if let own = block.ownFilters { Label("Свой фильтр · " + CalendarDays.range(own), systemImage: "line.3.horizontal.decrease").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
            content(db: db, filters: block.ownFilters ?? db.settings.dashboardFilters)
        }.frame(maxWidth: .infinity, alignment: .leading).beeCard()
    } }
    @ViewBuilder private func content(db: Database, filters: Filters) -> some View {
        let currency = db.settings.reportCurrency
        switch block.kind {
        case "balances":
            DashboardAccountBalances(db: db, filters: filters)
        case "flows":
            let operations = Reports.selected(db, filters: filters, kinds: [.income, .expense])
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { flow("Доходы", ops: operations.filter { $0.kind == .income }, db: db, filters: filters, color: BeeStyle.positive).fixedSize(); flow("Расходы", ops: operations.filter { $0.kind == .expense }, db: db, filters: filters, color: BeeStyle.expense).fixedSize() }
                VStack(alignment: .leading, spacing: 16) { flow("Доходы", ops: operations.filter { $0.kind == .income }, db: db, filters: filters, color: BeeStyle.positive); flow("Расходы", ops: operations.filter { $0.kind == .expense }, db: db, filters: filters, color: BeeStyle.expense) }
            }
            Divider()
            if let net = try? Reports.sum(operations, db: db, currency: currency, net: true) { HStack { Text("Разница").beeFont(.subheadline); Spacer(); PartialValue(value: net, currency: currency) }; Text("Доходы минус расходы · переводы исключены").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
        case "trend": TrendChart(filters: filters, currency: currency)
        case "categories", "outside":
            var selected = filters; let _ = selected.participation = block.kind == "outside" ? .outside : selected.participation
            let report = standardReport(metric: .expense, grouping: .category, filters: selected, db: db)
            if let rows = try? Reports.rows(report, db: db), !rows.isEmpty {
                ForEach(rows.sorted { $0.value.known > $1.value.known }.prefix(block.kind == "outside" ? 3 : 5)) { row in Button { model.showOperations(row.operationIDs, title: row.title, filters: selected) } label: { HStack { Text(row.title).lineLimit(1); Spacer(); Text(BeeFormat.valuation(row.value, currency: currency)).monospacedDigit(); Image(systemName: "chevron.right").beeFont(.caption) } }.buttonStyle(BeeRowStyle()) }
                Button("Все расходы →") { model.showOperations(Reports.selected(db, filters: selected, kinds: [.expense]).map(\.id), title: dashboardTitle(block, db: db), filters: selected) }.buttonStyle(BeeRowStyle()).beeFont(.caption).foregroundStyle(BeeStyle.muted)
            } else { Text("Нет расходов в выбранной выборке").beeFont(.subheadline).foregroundStyle(BeeStyle.muted) }
        case "monthly", "projects":
            let plans = db.budgets.filter { block.kind == "monthly" ? $0.kind == .monthly && $0.start.month == (filters.start ?? .today).month : $0.kind == .project && !$0.completed }
            if plans.isEmpty {
                Text("Бюджет не задан").beeFont(.subheadline).foregroundStyle(BeeStyle.muted); Button("Создать бюджет") { model.sheet = SheetRoute(kind: .budget, budgetKind: block.kind == "monthly" ? .monthly : .project) }.buttonStyle(BeeRowStyle())
            }
            ForEach(plans.prefix(2)) { budget in BudgetSummary(budget: budget, filters: filters) }
            if block.kind == "projects" { let report = standardReport(metric: .expense, grouping: .project, filters: filters, db: db); if let rows = try? Reports.rows(report, db: db) { ForEach(rows.prefix(3)) { row in Button { model.showOperations(row.operationIDs, title: row.title, filters: filters) } label: { HStack { Text(row.title); Spacer(); Text(BeeFormat.valuation(row.value, currency: currency)) } }.buttonStyle(BeeRowStyle()).beeFont(.caption) } } }
        default:
            if var report = db.reports.first(where: { $0.id == block.reportID }) { let _ = report.filters = filters; if report.dataset == .balances { let _ = report.filters.categories = []; let _ = report.filters.projectID = nil; let _ = report.filters.participation = .all }; ReportDisplay(report: report) }
        }
    }
    private func flow(_ title: String, ops: [BudgetCore.Operation], db: Database, filters: Filters, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).beeFont(.subheadline).foregroundStyle(color); if let value = try? Reports.sum(ops, db: db, currency: db.settings.reportCurrency) { Button { model.showOperations(ops.map(\.id), title: title, filters: filters) } label: { Text(BeeFormat.money(value.known, currency: db.settings.reportCurrency)).beeFont(.system(size: 23, weight: .semibold)).monospacedDigit().fixedSize(horizontal: false, vertical: true) }.buttonStyle(BeeRowStyle()).accessibilityLabel("Открыть операции: " + title); if value.partial { PartialStatus(value: value) } }; Text("\(ops.count) операций").beeFont(.caption).foregroundStyle(BeeStyle.muted) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

func standardReport(metric: Metric, grouping: Grouping, filters: Filters, db: Database) -> Report { var report = Report(name: metric.title); report.metric = metric; report.grouping = grouping; report.filters = filters; report.currency = db.settings.reportCurrency; return report }

struct TrendChart: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @Environment(\.beeAppearance) private var appearance
    @EnvironmentObject var model: AppModel
    var filters: Filters
    var currency: String
    var body: some View { if let db = model.db {
        let income = (try? Reports.rows(standardReport(metric: .income, grouping: .day, filters: filters, db: db), db: db)) ?? []
        let expense = (try? Reports.rows(standardReport(metric: .expense, grouping: .day, filters: filters, db: db), db: db)) ?? []
        if income.isEmpty && expense.isEmpty { Text("Нет потоковых операций").foregroundStyle(BeeStyle.muted) }
        else {
            Chart {
                ForEach(income.sorted { $0.id < $1.id }) { row in LineMark(x: .value("Дата", row.title), y: .value("Сумма", major(row.value.known)), series: .value("Поток", "Доходы")).foregroundStyle(BeeStyle.positive); PointMark(x: .value("Дата", row.title), y: .value("Сумма", major(row.value.known))).foregroundStyle(BeeStyle.positive) }
                ForEach(expense.sorted { $0.id < $1.id }) { row in LineMark(x: .value("Дата", row.title), y: .value("Сумма", major(row.value.known)), series: .value("Поток", "Расходы")).foregroundStyle(BeeStyle.expense); PointMark(x: .value("Дата", row.title), y: .value("Сумма", major(row.value.known))).foregroundStyle(BeeStyle.expense) }
            }.chartXScale(domain: Array(Set((income + expense).map(\.title))).sorted()).chartXAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let raw = value.as(String.self), let day = try? Day(raw) { Text(CalendarDays.label(day)).beeFont(.caption).foregroundStyle(BeeStyle.muted) } } } }.chartYAxis { AxisMarks { axis in AxisGridLine().foregroundStyle(BeeStyle.line.opacity(0.25)); AxisValueLabel { if let number = axis.as(Double.self) { Text(number.formatted(.number.precision(.fractionLength(0)))).beeFont(.caption).foregroundStyle(BeeStyle.muted) } } } }.frame(height: 160 * appearance.scale)
            HStack { Label("Доходы", systemImage: "circle.fill").foregroundStyle(BeeStyle.positive); Label("Расходы", systemImage: "circle.fill").foregroundStyle(BeeStyle.expense) }.beeFont(.caption)
            if (income + expense).contains(where: { $0.value.partial }) { Text("График частичный: есть операции без курса").beeFont(.caption).foregroundStyle(BeeStyle.warning) }
        }
    } }
    private func major(_ amount: Int64) -> Double { Double(amount) / pow(10, Double((try? Currency.get(currency).scale) ?? 2)) }
}

struct BudgetSummary: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var budget: Budget
    var filters: Filters
    var body: some View { if let db = model.db, let fact = try? Reports.budgetFact(budget, db: db, filters: filters), let plan = try? budget.plan {
        VStack(alignment: .leading, spacing: 8) {
            Button(budget.name) { model.section = .budgets }.buttonStyle(BeeRowStyle()).beeFont(.subheadline.bold())
            Text("\(BeeFormat.valuation(fact, currency: budget.currency)) / \(BeeFormat.money(plan, currency: budget.currency))").beeFont(.caption).monospacedDigit()
            if plan > 0 { ProgressView(value: min(1, Double(fact.known) / Double(plan))).tint(fact.known > plan ? BeeStyle.negative : BeeStyle.expense) }
            Text(fact.known > plan ? "Превышение: " + BeeFormat.money(fact.known - plan, currency: budget.currency) : "Факт по фильтрам · полный план").beeFont(.caption).foregroundStyle(fact.known > plan ? BeeStyle.negative : BeeStyle.muted)
        }
    } }
}

struct LayoutEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @State private var blocks: [DashboardBlock] = []
    @State private var original: [DashboardBlock] = []
    @State private var loaded = false
    @State private var resetting = false
    var body: some View {
        EditorFrame(title: "Настроить Главную", saveTitle: "Готово", isDirty: blocks != original, width: 720, height: 650, save: { try model.commit { $0.dashboard = blocks } }) {
            Text("Переместите блоки, выберите размер и скройте лишнее.").foregroundStyle(BeeStyle.muted)
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Image(systemName: "line.3.horizontal").foregroundStyle(BeeStyle.muted); Toggle(dashboardTitle(block, db: model.db), isOn: Binding(get: { blocks[index].visible }, set: { blocks[index].visible = $0 })).toggleStyle(.checkbox); Spacer(); BeePicker("Размер", selection: Binding(get: { blocks[index].wide }, set: { blocks[index].wide = $0 })) { Text("Обычный").tag(false); Text("Широкий").tag(true) }.frame(width: 160); Button("Выше", systemImage: "arrow.up") { blocks.swapAt(index, index - 1) }.labelStyle(.iconOnly).disabled(index == 0); Button("Ниже", systemImage: "arrow.down") { blocks.swapAt(index, index + 1) }.labelStyle(.iconOnly).disabled(index == blocks.count - 1) }
                    DisclosureGroup("Фильтры блока") { Toggle("Использовать свои условия", isOn: Binding(get: { blocks[index].ownFilters != nil }, set: { blocks[index].ownFilters = $0 ? model.db?.settings.dashboardFilters ?? .month : nil })).toggleStyle(.checkbox); if blocks[index].ownFilters != nil { FilterBar(filters: Binding(get: { blocks[index].ownFilters ?? .month }, set: { blocks[index].ownFilters = $0 })) } }
                }.padding(12).background(BeeStyle.selected, in: RoundedRectangle(cornerRadius: 9))
                    .draggable(block.id.uuidString).dropDestination(for: String.self) { values, _ in guard let value = values.first, let source = blocks.firstIndex(where: { $0.id.uuidString == value }), let target = blocks.firstIndex(where: { $0.id == block.id }), source != target else { return false }; let moved = blocks.remove(at: source); blocks.insert(moved, at: min(target, blocks.count)); return true }
            }
            Menu("Добавить блок") {
                ForEach(DashboardBlock.defaults.filter { standard in !blocks.contains(where: { $0.kind == standard.kind }) }) { standard in Button(dashboardTitle(standard, db: model.db)) { blocks.append(standard) } }
                ForEach(model.db?.reports.filter { report in !blocks.contains(where: { $0.reportID == report.id }) } ?? []) { report in Button(report.name) { blocks.append(DashboardBlock(kind: "report", reportID: report.id)) } }
            }
            Button("Вернуть стандартный набор") { resetting = true }
        }.onAppear { guard !loaded else { return }; loaded = true; blocks = model.db?.dashboard ?? []; original = blocks }
            .confirmationDialog("Заменить раскладку стандартной? Собственные фильтры блоков будут сняты.", isPresented: $resetting) { Button("Вернуть стандартный набор", role: .destructive) { blocks = DashboardBlock.defaults }; Button("Отмена", role: .cancel) {} }
    }
}
