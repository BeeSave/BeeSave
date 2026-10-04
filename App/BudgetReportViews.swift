import SwiftUI
import Charts
import BudgetCore

struct BudgetsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { if let db = model.db { ScrollView { VStack(alignment: .leading, spacing: 20) {
        HStack { Text("Планы расходов").font(.largeTitle.bold()); Spacer(); Button("Новый бюджет", systemImage: "plus") { model.sheet = SheetRoute(kind: .budget) } }
        if db.budgets.isEmpty { EmptyState(title: "Бюджет не задан", detail: "Расходы можно вести без плана. Создайте месячный или проектный бюджет, когда понадобится.", icon: "chart.pie") }
        ForEach(db.budgets.sorted { $0.start > $1.start }) { b in BudgetCard(budget: b) }
    }.padding(24) } } }
}
struct BudgetCard: View {
    @EnvironmentObject var model: AppModel; var budget: Budget; var filters: Filters?
    var body: some View { if let db = model.db { GroupBox { VStack(alignment: .leading, spacing: 14) {
        HStack { VStack(alignment: .leading) { Text(budget.name).font(.title3.bold()); Text("\(budget.kind.title) · \(budget.start.rawValue) — \(budget.endDate?.rawValue ?? "без окончания")\(budget.completed ? " · завершён" : "")").font(.caption).foregroundStyle(.secondary) }; Spacer(); if filters == nil { Menu("Действия") {
            Button("Изменить") { model.sheet = SheetRoute(kind: .budget, entityID: budget.id) }
            if budget.kind == .project { Button(budget.completed ? "Открыть снова" : "Завершить сегодня") { model.perform { db in var b = budget; b.completed.toggle(); b.end = b.completed ? .today : nil; try Ledger.saveBudget(b, in: &db) } } }
            Button("Удалить бюджет", role: .destructive) { if confirmDeletion(budget.name, consequence: "Удаляется только план. Расходы и проекты сохраняются.") { model.perform { $0.budgets.removeAll { $0.id == budget.id } } } }
        } } }
        if let fact = try? Reports.budgetFact(budget, db: db, filters: filters), let plan = try? budget.plan {
            let (remaining, overflow) = plan.subtractingReportingOverflow(fact.known)
            HStack { metric("План", Money.display(plan, currency: budget.currency)); metric(filters == nil ? "Факт" : "Факт по фильтрам / полный план", fact.label(currency: budget.currency)); if !overflow { metric("Остаток", Money.display(remaining, currency: budget.currency), negative: remaining < 0) } }
            if plan == 0 { Text("Выполнение: —").foregroundStyle(.secondary) }
            else { Text("Выполнение: \(NSDecimalNumber(decimal: Decimal(fact.known) / Decimal(plan) * 100).stringValue.prefix(8))%" + (fact.partial ? " · частично" : "")) }
            if fact.known > plan { Text("Превышение: " + Money.display(fact.known - plan, currency: budget.currency)).foregroundStyle(.red) }
            if fact.partial { Text("Добавьте курс для неоценённых операций: \(fact.missing.count).").foregroundStyle(.orange) }
            ForEach(budget.lines) { line in HStack { Text(db.categoryPath(line.categoryID)); Spacer(); Text("План " + Money.display(line.limit, currency: budget.currency)); if let value = try? Reports.budgetFact(budget, db: db, lineID: line.id, filters: filters) { Text("Факт " + value.label(currency: budget.currency)) }; Text(line.limit == 0 ? "—" : "") }.font(.caption) }
            Button("Показать расходы") { let ops = filters.map { Reports.selected(db, filters: $0, kinds: [.expense]) } ?? db.operations; model.showOperations(ops.filter { Ledger.matches($0, budget: budget, db: db) }.map(\.id)) }
        } else { Text("Ошибка расчёта: проверьте суммы и курсы.").foregroundStyle(.red) }
    }.padding(12) } } }
    func metric(_ title: String, _ text: String, negative: Bool = false) -> some View { VStack(alignment: .leading) { Text(title).font(.caption).foregroundStyle(.secondary); Text(text).font(.headline).foregroundStyle(negative ? .red : .primary) }.frame(maxWidth: .infinity, alignment: .leading) }
}
struct PlanLine: Identifiable { var id = UUID(); var categoryID: UUID?; var limit = "0" }
struct BudgetEditor: View {
    @EnvironmentObject var model: AppModel; var id: UUID?
    @State private var kind = BudgetKind.monthly; @State private var name = ""; @State private var currency = "RUB"; @State private var start = Day.today.firstOfMonth.rawValue; @State private var end = ""; @State private var projectID: UUID?; @State private var limit = ""; @State private var lines: [PlanLine] = [PlanLine()]
    var body: some View { EditorFrame(title: id == nil ? "Новый бюджет" : "Изменить бюджет", save: save) {
        Picker("Вид", selection: $kind) { ForEach(BudgetKind.allCases, id: \.self) { Text($0.title).tag($0) } }.disabled(id != nil)
        TextField("Название", text: $name); CurrencyPicker(title: "Валюта бюджета", selection: $currency); DayField(title: kind == .monthly ? "Первый день месяца" : "Начало", value: $start)
        if kind == .monthly {
            ForEach($lines) { $line in HStack { Picker("Категория", selection: $line.categoryID) { Text("Выберите").tag(nil as UUID?); ForEach(model.db?.categories.filter { $0.kind == .expense && !$0.archived } ?? []) { Text(model.db?.categoryPath($0.id) ?? $0.name).tag(Optional($0.id)) } }; TextField("Лимит", text: $line.limit).frame(width: 140); Button { lines.removeAll { $0.id == line.id } } label: { Image(systemName: "minus.circle") } } }
            Button("Добавить строку") { lines.append(PlanLine()) }; Text("Родитель охватывает своё поддерево. Одновременные строки родителя и подкатегории недопустимы.").font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Проект", selection: $projectID) { Text("Выберите").tag(nil as UUID?); ForEach(model.db?.projects.filter { !$0.archived } ?? []) { Text($0.name).tag(Optional($0.id)) } }; TextField("Положительный лимит", text: $limit); DayField(title: "Окончание (можно оставить пустым)", value: $end)
        }
        Text("Лимиты не блокируют расход. Доходы не восстанавливают лимит. Автоматические расходы прошлого периода пересчитаются после создания плана.").font(.caption).foregroundStyle(.secondary)
    }.onAppear { currency = model.db?.settings.baseCurrency ?? "RUB"; if let b = model.db?.budgets.first(where: { $0.id == id }) { name = b.name; kind = b.kind; currency = b.currency; start = b.start.rawValue; end = b.end?.rawValue ?? ""; projectID = b.projectID; limit = Money.string(b.limit, currency: b.currency); lines = b.lines.map { PlanLine(categoryID: $0.categoryID, limit: Money.string($0.limit, currency: b.currency)) } } } }
    func save() throws {
        var b = try model.db?.budgets.first { $0.id == id } ?? Budget(kind: kind, name: name, currency: currency, start: Day(start)); b.name = name; b.currency = currency; b.start = try Day(start)
        if kind == .monthly { b.start = b.start.firstOfMonth; b.lines = try lines.map { guard let category = $0.categoryID else { throw BudgetError.invalid("Выберите категорию каждой строки.") }; return BudgetLine(categoryID: category, limit: try Money.parse($0.limit, currency: currency)) } }
        else { b.projectID = projectID; b.limit = try Money.parse(limit, currency: currency); b.end = end.isEmpty ? nil : try Day(end) }
        try model.commit { try Ledger.saveBudget(b, in: &$0) }
    }
}

extension Dataset { var title: String { self == .flows ? "Доходы / расходы" : "Остатки" } }
extension Metric { var title: String { switch self { case .income: "Сумма доходов"; case .expense: "Сумма расходов"; case .net: "Доходы минус расходы"; case .count: "Количество операций"; case .balance: "Остаток" } } }
extension Grouping { var title: String { switch self { case .day: "День"; case .month: "Месяц"; case .account: "Счёт"; case .category: "Категория"; case .subcategory: "Подкатегория"; case .project: "Проект" } } }
extension Presentation { var title: String { switch self { case .table: "Таблица"; case .bars: "Столбцы"; case .line: "Линия"; case .ring: "Кольцо" } } }
struct ReportEditor: View {
    @EnvironmentObject var model: AppModel; var id: UUID?; @State private var report = Report(name: "Новый отчёт"); @State private var addDashboard = true
    var groupings: [Grouping] { report.dataset == .balances ? [.day, .month, .account] : Grouping.allCases }
    var ringAllowed: Bool {
        guard report.metric != .net else { return false }
        guard report.dataset == .balances else { return true }
        guard let db = model.db else { return false }; var candidate = report; candidate.presentation = .table
        guard let rows = try? Reports.rows(candidate, db: db) else { return false }
        return !rows.contains { $0.value.known < 0 }
    }
    var presentations: [Presentation] { Presentation.allCases.filter { ($0 != .line || [.day, .month].contains(report.grouping)) && ($0 != .ring || ringAllowed) } }
    var body: some View { EditorFrame(title: "Конструктор отчёта", save: save) {
        TextField("Название", text: $report.name); Picker("Данные", selection: $report.dataset) { ForEach(Dataset.allCases, id: \.self) { Text($0.title).tag($0) } }.onChange(of: report.dataset) { if report.dataset == .balances { report.metric = .balance; report.grouping = .account; report.filters.categories = []; report.filters.projectID = nil } else { report.metric = .expense } }
        Picker("Показатель", selection: $report.metric) { ForEach(report.dataset == .balances ? [.balance] : [Metric.income, .expense, .net, .count], id: \.self) { Text($0.title).tag($0) } }
        Picker("Группировка", selection: $report.grouping) { ForEach(groupings, id: \.self) { Text($0.title).tag($0) } }.onChange(of: report.grouping) { if !presentations.contains(report.presentation) { report.presentation = .table } }
        Picker("Представление", selection: $report.presentation) { ForEach(presentations, id: \.self) { Text($0.title).tag($0) } }.onChange(of: report.metric) { if !presentations.contains(report.presentation) { report.presentation = .table } }
        CurrencyPicker(title: "Валюта", selection: $report.currency); FilterBar(filters: $report.filters, showParticipation: report.dataset == .flows, allowCategoryProject: report.dataset == .flows)
        if report.dataset == .balances { Text("Категории и проекты к остаткам не применяются. Остаток на день — конец дня; на текущий месяц — сегодняшняя дата.").font(.caption).foregroundStyle(.secondary) }
        Toggle("Добавить на Главную", isOn: $addDashboard); ReportDisplay(report: report)
    }.onAppear { if let old = model.db?.reports.first(where: { $0.id == id }) { report = old; addDashboard = model.db?.dashboard.contains { $0.reportID == old.id } ?? false } else { report.currency = model.db?.settings.reportCurrency ?? "RUB" } } }
    func save() throws { try model.commit { db in try Reports.validate(report, db: db); if let i = db.reports.firstIndex(where: { $0.id == report.id }) { db.reports[i] = report } else { db.reports.append(report) }; if addDashboard && !db.dashboard.contains(where: { $0.reportID == report.id }) { db.dashboard.append(DashboardBlock(kind: "report", reportID: report.id)) } } }
}
struct ReportDisplay: View {
    @EnvironmentObject var model: AppModel; var report: Report
    var result: Result<[ReportRow], Error> { Result { guard let db = model.db else { throw BudgetError.locked }; return try Reports.rows(report, db: db) } }
    var body: some View {
        switch result {
        case .failure(let e): Text(e.localizedDescription).foregroundStyle(.red)
        case .success(let rows):
            if rows.isEmpty { EmptyState(title: "Нет данных", detail: "В выбранном периоде и фильтрах нет подходящих операций.") }
            else { VStack(alignment: .leading, spacing: 10) {
                if let v = report.dataset == .balances && report.grouping != .account ? rows.last?.value : try? Reports.total(rows) { Text(report.metric == .count ? "\(v.known) операций" : v.label(currency: report.currency)).font(.title3.bold()) }
                if report.presentation != .table { Chart(rows) { row in
                    let value = Double(row.value.known) / (report.metric == .count ? 1 : pow(10, Double((try? Currency.get(report.currency).scale) ?? 2)))
                    if report.presentation == .bars { BarMark(x: .value("Группа", row.title), y: .value("Значение", value)).foregroundStyle(.teal) }
                    else if report.presentation == .line { LineMark(x: .value("Дата", row.title), y: .value("Значение", value)).foregroundStyle(.teal); PointMark(x: .value("Дата", row.title), y: .value("Значение", value)) }
                    else { SectorMark(angle: .value("Значение", value), innerRadius: .ratio(0.65)).foregroundStyle(by: .value("Группа", row.title)) }
                }.frame(height: 220) }
                ForEach(rows) { row in HStack { Text(row.title); Spacer(); Text(report.metric == .count ? String(row.value.known) : row.value.label(currency: report.currency)).monospacedDigit(); Button("Детали") { if !row.operationIDs.isEmpty { model.showOperations(row.operationIDs) } else if let id = row.accountIDs.first { model.openHistory(id) } }.controlSize(.small) } }
            } }
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    var filters: Binding<Filters> { Binding(get: { model.db?.settings.dashboardFilters ?? .month }, set: { f in model.perform { $0.settings.dashboardFilters = f } }) }
    var currency: Binding<String> { Binding(get: { model.db?.settings.reportCurrency ?? "RUB" }, set: { c in model.perform { $0.settings.reportCurrency = c } }) }
    var gridRows: [[DashboardBlock]] {
        var result: [[DashboardBlock]] = []; var pair: [DashboardBlock] = []
        for b in model.db?.dashboard.filter(\.visible) ?? [] { if b.wide { if !pair.isEmpty { result.append(pair); pair = [] }; result.append([b]) } else { pair.append(b); if pair.count == 2 { result.append(pair); pair = [] } } }; if !pair.isEmpty { result.append(pair) }; return result
    }
    var body: some View { if let db = model.db { ScrollView { VStack(alignment: .leading, spacing: 18) {
        HStack { VStack(alignment: .leading) { Text("Домашний бюджет").font(.largeTitle.bold()); Text("\(db.settings.dashboardFilters.start?.rawValue ?? "всё время") — \(db.settings.dashboardFilters.end?.rawValue ?? "сегодня")").foregroundStyle(.secondary) }; Spacer(); Button("Настроить блоки") { model.sheet = SheetRoute(kind: .layout) }; Button("Создать отчёт") { model.sheet = SheetRoute(kind: .report) } }
        CurrencyPicker(title: "Валюта отображения", selection: currency); FilterBar(filters: filters)
        Grid(horizontalSpacing: 18, verticalSpacing: 18) { ForEach(Array(gridRows.enumerated()), id: \.offset) { _, row in GridRow { ForEach(row) { block in GroupBox { VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title(block)).font(.title3.bold()); Spacer(); if let id = block.reportID { Button("Изменить") { model.sheet = SheetRoute(kind: .report, entityID: id) } } }
            if let own = block.ownFilters { Text("Собственные фильтры: \(own.start?.rawValue ?? "всё") — \(own.end?.rawValue ?? "сегодня"), счета \(own.accounts.count), категории \(own.categories.count)").font(.caption).foregroundStyle(.secondary) }
            blockContent(block, db: db)
        }.padding(10) }.frame(maxWidth: .infinity, alignment: .leading).gridCellColumns(block.wide ? 2 : 1) } } } }
        if !db.reports.isEmpty { Text("Сохранённые отчёты").font(.title2.bold()); ForEach(db.reports) { r in HStack { Button(r.name) { model.sheet = SheetRoute(kind: .report, entityID: r.id) }; Spacer(); Button("На Главную") { model.perform { if !$0.dashboard.contains(where: { $0.reportID == r.id }) { $0.dashboard.append(DashboardBlock(kind: "report", reportID: r.id)) } } }; Button("Удалить", role: .destructive) { if confirmDeletion(r.name, consequence: "Удаляется настройка отчёта и его блоки, финансовые операции сохраняются.") { model.perform { $0.reports.removeAll { $0.id == r.id }; $0.dashboard.removeAll { $0.reportID == r.id } } } } } } }
    }.padding(24) } } }
    func title(_ b: DashboardBlock) -> String { switch b.kind { case "balances": "Остатки по счетам"; case "flows": "Доходы, расходы и разница"; case "trend": "Динамика доходов и расходов"; case "categories": "Расходы по категориям"; case "monthly": "Месячный бюджет"; case "projects": "Бюджеты и расходы проектов"; case "outside": "Расходы вне бюджетов"; default: model.db?.reports.first { $0.id == b.reportID }?.name ?? "Отчёт" } }
    @ViewBuilder func blockContent(_ b: DashboardBlock, db: Database) -> some View {
        let f = b.ownFilters ?? db.settings.dashboardFilters
        if b.kind == "balances" {
            Text("Текущие остатки: период, категории и проекты не применяются. Оценка использует справочные курсы на сегодня.").font(.caption).foregroundStyle(.secondary)
            if let rows = try? Reports.balances(db, filters: f, currency: db.settings.reportCurrency) { if let total = try? Reports.total(rows) { Text(total.label(currency: db.settings.reportCurrency)).font(.title2.bold()).foregroundStyle(total.known < 0 ? .red : .primary) }; ForEach(rows) { row in Button { if let id = row.accountIDs.first { model.openHistory(id) } } label: { HStack { Text(row.title); Spacer(); Text(row.value.label(currency: db.settings.reportCurrency)).foregroundStyle(row.value.known < 0 ? .red : .primary) } }.buttonStyle(.plain) }; if rows.isEmpty { EmptyState(title: "Счетов пока нет", detail: "Создайте первый счёт.") } }
        } else if b.kind == "monthly" || b.kind == "projects" {
            let budgets = db.budgets.filter { b.kind == "monthly" ? $0.kind == .monthly && $0.start.month == (f.start ?? .today).month : $0.kind == .project }
            if budgets.isEmpty { EmptyState(title: "Бюджет не задан", detail: "Можно продолжать учёт расходов без плана.") }
            ForEach(budgets) { BudgetCard(budget: $0, filters: f) }
            if b.kind == "projects" { ReportDisplay(report: standard(metric: .expense, grouping: .project, filters: f, db: db)) }
        } else if b.kind == "flows" {
            HStack { ForEach([Metric.income, .expense, .net], id: \.self) { m in VStack(alignment: .leading) { Text(m.title).font(.caption).foregroundStyle(.secondary); ReportDisplay(report: standard(metric: m, grouping: .month, filters: f, db: db)) }.frame(maxWidth: .infinity, alignment: .leading) } }
        } else if b.kind == "report", let r = db.reports.first(where: { $0.id == b.reportID }) { ReportDisplay(report: blockReport(r, filters: f)) }
        else if b.kind == "trend" { ReportDisplay(report: standard(metric: .income, grouping: .day, filters: f, presentation: .line, db: db)); ReportDisplay(report: standard(metric: .expense, grouping: .day, filters: f, presentation: .line, db: db)) }
        else if b.kind == "outside" { var outside = f; let _ = outside.participation = .outside; ReportDisplay(report: standard(metric: .expense, grouping: .category, filters: outside, db: db)) }
        else { ReportDisplay(report: standard(metric: .expense, grouping: .category, filters: f, presentation: .bars, db: db)) }
    }
    func standard(metric: Metric, grouping: Grouping, filters: Filters, presentation: Presentation = .table, db: Database) -> Report { var r = Report(name: metric.title); r.metric = metric; r.grouping = grouping; r.filters = filters; r.currency = db.settings.reportCurrency; r.presentation = presentation; return r }
    func blockReport(_ report: Report, filters: Filters) -> Report { var r = report; r.filters = filters; if r.dataset == .balances { r.filters.categories = []; r.filters.projectID = nil; r.filters.participation = .all }; return r }
}
struct LayoutEditor: View {
    @EnvironmentObject var model: AppModel; @State private var blocks: [DashboardBlock] = []; @State private var selected: UUID?
    var body: some View { EditorFrame(title: "Блоки Главной", save: { try model.commit { $0.dashboard = blocks } }) {
        ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in VStack(alignment: .leading) {
            HStack { Toggle(block.kind == "report" ? model.db?.reports.first { $0.id == block.reportID }?.name ?? "Отчёт" : DashboardView().title(block), isOn: Binding(get: { blocks[index].visible }, set: { blocks[index].visible = $0 })); Spacer(); Toggle("Широкий", isOn: Binding(get: { blocks[index].wide }, set: { blocks[index].wide = $0 })); Button("↑") { blocks.swapAt(index, index - 1) }.disabled(index == 0); Button("↓") { blocks.swapAt(index, index + 1) }.disabled(index == blocks.count - 1) }
            Toggle("Собственные фильтры", isOn: Binding(get: { blocks[index].ownFilters != nil }, set: { blocks[index].ownFilters = $0 ? .month : nil }))
            if blocks[index].ownFilters != nil { FilterBar(filters: Binding(get: { blocks[index].ownFilters ?? .month }, set: { blocks[index].ownFilters = $0 })) }
        }.padding(8) }
        Button("Вернуть стандартный набор") { blocks = DashboardBlock.defaults }
    }.onAppear { blocks = model.db?.dashboard ?? [] } }
}
