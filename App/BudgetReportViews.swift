import SwiftUI
import Charts
import BudgetCore
import BudgetPresentation

struct BudgetsView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @State private var kind = BudgetKind.monthly
    var body: some View { if let db = model.db { ScrollView { VStack(alignment: .leading, spacing: 18) {
        SectionHeading(title: "Бюджет") { Button(kind == .monthly ? "Месячный бюджет" : "Проектный бюджет", systemImage: "plus") { model.sheet = SheetRoute(kind: .budget, budgetKind: kind) }.buttonStyle(BeePrimaryStyle()) }
        BeePicker("Бюджеты", selection: $kind) { Text("Месячные").tag(BudgetKind.monthly); Text("Проектные").tag(BudgetKind.project) }.beePickerStyle(.segmented)
        if !db.budgets.contains(where: { $0.kind == kind }) { EmptyState(title: "Бюджет не задан", detail: "Можно вести расходы без плана и добавить его позже.", icon: "chart.pie").beeCard() }
        ForEach(db.budgets.filter { $0.kind == kind }.sorted { $0.start > $1.start }) { budget in BudgetCard(budget: budget) }
    }.padding(26) } } }
}
struct BudgetCard: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var budget: Budget
    var filters: Filters?
    var body: some View { if let db = model.db {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) { VStack(alignment: .leading, spacing: 6) { Text(budget.name).beeFont(.title3.bold()); Text(CalendarDays.label(budget.start) + " — " + (budget.endDate.map { CalendarDays.label($0) } ?? "без окончания") + (budget.completed ? " · завершён" : "")).beeFont(.caption).foregroundStyle(BeeStyle.muted) }; Spacer(); Menu {
                Button("Изменить") { model.sheet = SheetRoute(kind: .budget, entityID: budget.id) }
                if budget.kind == .project { Button(budget.completed ? "Открыть снова" : "Завершить сегодня") { model.perform { db in var copy = budget; copy.completed.toggle(); copy.end = copy.completed ? .today : nil; try Ledger.saveBudget(copy, in: &db) } } }
                Button("Удалить бюджет", role: .destructive) { if confirmDeletion(budget.name, consequence: "Удаляется только план. Расходы и проекты сохраняются.") { model.perform { $0.budgets.removeAll { $0.id == budget.id } } } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28) }
            if let fact = try? Reports.budgetFact(budget, db: db, filters: filters), let plan = try? budget.plan {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) { Text("План").beeFont(.caption).foregroundStyle(BeeStyle.muted); Text(BeeFormat.money(plan, currency: budget.currency)).beeFont(.title3).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) { Text(filters == nil ? "Факт" : "Факт по фильтрам").beeFont(.caption).foregroundStyle(BeeStyle.muted); PartialValue(value: fact, currency: budget.currency) }.frame(maxWidth: .infinity, alignment: .leading)
                    let (remaining, overflow) = plan.subtractingReportingOverflow(fact.known)
                    VStack(alignment: .leading, spacing: 8) { Text("Остаток").beeFont(.caption).foregroundStyle(BeeStyle.muted); Text(overflow ? "Не удалось оценить" : BeeFormat.money(remaining, currency: budget.currency)).beeFont(.title3).monospacedDigit().foregroundStyle(remaining < 0 ? BeeStyle.negative : BeeStyle.text) }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if plan > 0 { ProgressView(value: min(1, Double(fact.known) / Double(plan))).tint(fact.known > plan ? BeeStyle.negative : BeeStyle.expense); Text("Выполнение: \(NSDecimalNumber(decimal: Decimal(fact.known) / Decimal(plan) * 100).stringValue.prefix(8))%" + (fact.partial ? " · частично" : "")).beeFont(.caption).foregroundStyle(BeeStyle.muted) } else { Text("Выполнение: —").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
                if fact.known > plan { Text("Превышение: " + BeeFormat.money(fact.known - plan, currency: budget.currency)).foregroundStyle(BeeStyle.negative) }
                if !budget.lines.isEmpty { Divider(); HStack { Text("Категория"); Spacer(); Text("План").frame(width: 140, alignment: .trailing); Text("Факт").frame(width: 160, alignment: .trailing) }.beeFont(.caption).foregroundStyle(BeeStyle.muted)
                    ForEach(budget.lines) { line in HStack { Text(db.categoryPath(line.categoryID)); Spacer(); Text(BeeFormat.money(line.limit, currency: budget.currency)).frame(width: 140, alignment: .trailing); if let value = try? Reports.budgetFact(budget, db: db, lineID: line.id, filters: filters) { Text(BeeFormat.valuation(value, currency: budget.currency)).frame(width: 160, alignment: .trailing) } }.beeFont(.subheadline).monospacedDigit() }
                }
                Button("Открыть расходы →") { let operations = filters.map { Reports.selected(db, filters: $0, kinds: [.expense]) } ?? db.operations; model.showOperations(operations.filter { Ledger.matches($0, budget: budget, db: db) }.map(\.id), title: budget.name, filters: filters ?? Filters()) }.buttonStyle(BeeRowStyle()).beeFont(.subheadline)
            }
        }.beeCard()
    } }
}
struct PlanLine: Identifiable { var id = UUID(); var categoryID: UUID?; var limit = "0" }
struct BudgetEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var id: UUID?
    var initialKind = BudgetKind.monthly
    @State private var kind = BudgetKind.monthly
    @State private var name = ""
    @State private var currency = "RUB"
    @State private var start = Day.today.firstOfMonth.rawValue
    @State private var end = Day.today.rawValue
    @State private var endEnabled = false
    @State private var projectID: UUID?
    @State private var limit = ""
    @State private var lines: [PlanLine] = [PlanLine()]
    @State private var loaded = false
    @State private var original: [String] = []
    @State private var categoryOpen = false
    @State private var projectOpen = false
    @State private var categoryLine: UUID?
    @FocusState private var focus: Bool
    private var value: [String] { [kind.rawValue, name, currency, start, end, String(endEnabled), projectID?.uuidString ?? "", limit, lines.map { ($0.categoryID?.uuidString ?? "") + $0.limit }.joined()] }
    var body: some View {
        EditorFrame(title: kind == .monthly ? "Месячный бюджет" : "Проектный бюджет", isDirty: loaded && value != original, width: 620, height: 600, onError: { _ in focus = true }, save: save) {
            FormField(title: "Название") { TextField("Название плана", text: $name).textFieldStyle(BeeTextFieldStyle()).focused($focus) }
            if kind == .monthly { MonthField(value: $start) } else { DayField(title: "Начало проекта", value: $start) }
            CurrencyPicker(title: "Валюта бюджета", selection: $currency)
            if kind == .monthly {
                Text("Категории и лимиты").beeFont(.headline)
                ForEach($lines) { $line in HStack(alignment: .top) { FormField(title: "Категория") { BeePicker("Категория", selection: $line.categoryID) { Text("Выберите").tag(nil as UUID?); ForEach(model.db?.categories.filter { $0.kind == .expense && (!$0.archived || $0.id == line.categoryID) } ?? []) { Text(model.db?.categoryPath($0.id) ?? $0.name).tag(Optional($0.id)) } }.labelsHidden() }; FormField(title: "Лимит · \(currency)") { TextField("0", text: $line.limit).textFieldStyle(BeeTextFieldStyle()).frame(width: 120) }; Button { categoryLine = line.id; categoryOpen = true } label: { Image(systemName: "plus") }.help("Создать категорию").padding(.top, 24); Button { lines.removeAll { $0.id == line.id } } label: { Image(systemName: "minus.circle") }.help("Удалить строку").padding(.top, 24) } }
                Button("Добавить строку") { lines.append(PlanLine()) }; Text("Выбирайте родительскую категорию или её подкатегории — без пересечения строк.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
            } else {
                FormField(title: "Проект") { HStack { BeePicker("Проект", selection: $projectID) { Text("Выберите").tag(nil as UUID?); ForEach(model.db?.projects.filter { !$0.archived || $0.id == projectID } ?? []) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden(); Button { projectOpen = true } label: { Image(systemName: "plus") }.help("Создать проект") } }
                FormField(title: "Лимит · \(currency)") { TextField("Положительная сумма", text: $limit).textFieldStyle(BeeTextFieldStyle()) }
                Toggle("Указать окончание", isOn: $endEnabled).toggleStyle(.checkbox); if endEnabled { DayField(title: "Окончание", value: $end) }
            }
            Text("План не блокирует расходы. Доходы не восстанавливают лимит.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        }.onAppear { guard !loaded else { return }; kind = initialKind; currency = model.db?.settings.baseCurrency ?? "RUB"; if let budget = model.db?.budgets.first(where: { $0.id == id }) { name = budget.name; kind = budget.kind; currency = budget.currency; start = budget.start.rawValue; end = budget.end?.rawValue ?? Day.today.rawValue; endEnabled = budget.end != nil; projectID = budget.projectID; limit = Money.string(budget.limit, currency: budget.currency); lines = budget.lines.map { PlanLine(categoryID: $0.categoryID, limit: Money.string($0.limit, currency: budget.currency)) } }; original = value; loaded = true; focus = true }
            .sheet(isPresented: $categoryOpen) { CategoryEditor(id: nil, onSaved: { id in if let index = lines.firstIndex(where: { $0.id == categoryLine }) { lines[index].categoryID = id } }) }
            .sheet(isPresented: $projectOpen) { ProjectEditor(id: nil, onSaved: { projectID = $0 }) }
    }
    private func save() throws {
        var budget = try model.db?.budgets.first { $0.id == id } ?? Budget(kind: kind, name: name, currency: currency, start: Day(start)); budget.name = name; budget.currency = currency; budget.start = try Day(start)
        if kind == .monthly { budget.start = budget.start.firstOfMonth; budget.lines = try lines.map { guard let category = $0.categoryID else { throw BudgetError.invalid("Выберите категорию каждой строки.") }; return BudgetLine(categoryID: category, limit: try Money.parse($0.limit, currency: currency)) } }
        else { budget.projectID = projectID; budget.limit = try Money.parse(limit, currency: currency); budget.end = endEnabled ? try Day(end) : nil }
        try model.commit { try Ledger.saveBudget(budget, in: &$0) }
    }
}
struct MonthField: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @Binding var value: String
    private var day: Day { (try? Day(value)) ?? .today }
    private var year: Int { Day.calendar.component(.year, from: day.date) }
    private var month: Int { Day.calendar.component(.month, from: day.date) }
    var body: some View { FormField(title: "Месяц") { HStack { BeePicker("Месяц", selection: Binding(get: { month }, set: { update(month: $0, year: year) })) { ForEach(1...12, id: \.self) { index in Text(DateFormatter.monthNames[index - 1]).tag(index) } }.labelsHidden(); Stepper("\(String(year))", value: Binding(get: { year }, set: { update(month: month, year: $0) }), in: 1...9999).fixedSize() } } }
    private func update(month: Int, year: Int) { value = String(format: "%04d-%02d-01", year, month) }
}
private extension DateFormatter { static var monthNames: [String] { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); return formatter.standaloneMonthSymbols.map(\.capitalized) } }

extension Dataset { var title: String { switch self { case .flows: "Доходы / расходы"; case .balances: "Остатки"; case .debt: "Задолженность · факт"; case .financialPlan: "Обязательства · прогноз"; case .depositYield: "Доход депозита · прогноз" } }
    var metrics: [Metric] { switch self { case .flows: [.income, .expense, .net, .count]; case .balances: [.balance]; case .debt: [.balance, .principal, .interest, .fees]; case .financialPlan: [.payment, .grace]; case .depositYield: [.yield, .netYield] } }
}
extension Metric { var title: String { switch self { case .income: "Сумма доходов"; case .expense: "Сумма расходов"; case .net: "Доходы минус расходы"; case .count: "Количество операций"; case .balance: "Остаток / задолженность"; case .principal: "Тело задолженности"; case .interest: "Начисленные проценты"; case .fees: "Комиссии и штрафы"; case .payment: "Предстоящие платежи"; case .grace: "Погашение для льготы"; case .yield: "Проценты до удержаний"; case .netYield: "Проценты после удержаний" } } }
extension Grouping { var title: String { switch self { case .day: "День"; case .month: "Месяц"; case .account: "Счёт"; case .category: "Категория"; case .subcategory: "Подкатегория"; case .project: "Проект" } } }
extension Presentation { var title: String { switch self { case .table: "Таблица"; case .bars: "Столбцы"; case .line: "Линия"; case .ring: "Кольцо" } } }

struct ReportEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var id: UUID?
    @State private var report = Report(name: "Новый отчёт")
    @State private var original = Report(name: "")
    @State private var addDashboard = true
    @State private var originalAdd = true
    @State private var loaded = false
    @State private var candidate: Report?
    @State private var removed: [String] = []
    @State private var confirmDataset = false
    @State private var detail: OperationDetailContext?
    var groupings: [Grouping] { report.dataset != .flows ? [.day, .month, .account] : Grouping.allCases }
    var ringAllowed: Bool { guard report.metric != .net else { return false }; guard report.dataset == .balances else { return true }; guard let db = model.db else { return false }; var candidate = report; candidate.presentation = .table; guard let rows = try? Reports.rows(candidate, db: db) else { return false }; return !rows.contains { $0.value.known < 0 } }
    var presentations: [Presentation] { Presentation.allCases.filter { ($0 != .line || [.day, .month].contains(report.grouping)) && ($0 != .ring || ringAllowed) } }
    var body: some View {
        EditorFrame(title: "Конструктор отчёта", isDirty: loaded && (report != original || addDashboard != originalAdd), width: 680, height: 650, save: save) {
            FormField(title: "Название") { TextField("Название отчёта", text: $report.name).textFieldStyle(BeeTextFieldStyle()) }
            Text("Что считать").beeFont(.headline)
            FormField(title: "Данные") { BeePicker("Данные", selection: Binding(get: { report.dataset }, set: changeDataset)) { ForEach(Dataset.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden() }
            FormField(title: "Показатель") { BeePicker("Показатель", selection: $report.metric) { ForEach(report.dataset.metrics, id: \.self) { Text($0.title).tag($0) } }.labelsHidden() }
            Divider(); Text("Как показать").beeFont(.headline)
            HStack { FormField(title: "Группировка") { BeePicker("Группировка", selection: $report.grouping) { ForEach(groupings, id: \.self) { Text($0.title).tag($0) } }.labelsHidden() }; FormField(title: "Представление") { BeePicker("Представление", selection: $report.presentation) { ForEach(presentations, id: \.self) { Text($0.title).tag($0) } }.labelsHidden() } }
            CurrencyPicker(title: "Валюта отчёта", selection: $report.currency)
            Divider(); Text("Выборка").beeFont(.headline); FilterBar(filters: $report.filters, showParticipation: report.dataset == .flows, allowCategoryProject: report.dataset == .flows, kinds: report.metric == .income ? [.income] : report.metric == .expense ? [.expense] : [.income, .expense])
            if report.dataset != .flows { Text("Категории, проекты и участие в бюджетах к остаткам не применяются.").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
            Toggle("Добавить на Главную", isOn: $addDashboard).toggleStyle(.checkbox)
            DisclosureGroup("Предпросмотр") { ReportDisplay(report: report, onDetail: { ids, title, filters in detail = OperationDetailContext(title: title, ids: ids, filters: filters) }, onAccount: { id in detail = OperationDetailContext(title: "История счёта", accountID: id) }).padding(.top, 12) }
        }.onAppear { guard !loaded else { return }; if let old = model.db?.reports.first(where: { $0.id == id }) { report = old; addDashboard = model.db?.dashboard.contains { $0.reportID == old.id } ?? false } else { report.currency = model.db?.settings.reportCurrency ?? "RUB" }; original = report; originalAdd = addDashboard; loaded = true }
            .onChange(of: report.grouping) { normalizePresentation() }.onChange(of: report.metric) { normalizePresentation() }
            .sheet(item: $detail) { OperationDetailSheet(context: $0) }
            .confirmationDialog("Для нового набора данных будут сняты условия: " + removed.joined(separator: ", "), isPresented: $confirmDataset) { Button("Изменить данные") { if let candidate { report = candidate }; candidate = nil }; Button("Отмена", role: .cancel) { candidate = nil } }
    }
    private func changeDataset(_ dataset: Dataset) { guard dataset != report.dataset else { return }; let next = EditorContext.changingDataset(report, to: dataset, database: model.db); if next.1.isEmpty { report = next.0 } else { candidate = next.0; removed = next.1; confirmDataset = true } }
    private func normalizePresentation() { if !presentations.contains(report.presentation) { report.presentation = .table } }
    private func save() throws { try model.commit { db in try Reports.validate(report, db: db); if let index = db.reports.firstIndex(where: { $0.id == report.id }) { db.reports[index] = report } else { db.reports.append(report) }; if addDashboard && !db.dashboard.contains(where: { $0.reportID == report.id }) { db.dashboard.append(DashboardBlock(kind: "report", reportID: report.id)) }; if !addDashboard { db.dashboard.removeAll { $0.reportID == report.id } } } }
}
struct ReportViewer: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var id: UUID?
    @State private var editing = false
    @State private var detail: OperationDetailContext?
    var body: some View { if editing { ReportEditor(id: id) } else if let report = model.db?.reports.first(where: { $0.id == id }) {
        VStack(alignment: .leading, spacing: 20) { HStack { Text(report.name).beeFont(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction) }; Text("\(report.dataset.title) · \(report.metric.title) · \(report.currency) · \(CalendarDays.range(report.filters))").beeFont(.caption).foregroundStyle(BeeStyle.muted); ScrollView { ReportDisplay(report: report, onDetail: { ids, title, filters in detail = OperationDetailContext(title: title, ids: ids, filters: filters) }, onAccount: { id in detail = OperationDetailContext(title: "История счёта", accountID: id) }) }; Divider(); HStack { Button("Удалить отчёт", role: .destructive) { if confirmDeletion(report.name, consequence: "Операции сохранятся. Отчёт и его блоки будут удалены.") { model.perform { $0.reports.removeAll { $0.id == report.id }; $0.dashboard.removeAll { $0.reportID == report.id } }; dismiss() } }; Spacer(); Button("Изменить") { editing = true }; Button("На Главную") { model.perform { if !$0.dashboard.contains(where: { $0.reportID == report.id }) { $0.dashboard.append(DashboardBlock(kind: "report", reportID: report.id)) } } }.buttonStyle(BeePrimaryStyle()).disabled(model.db?.dashboard.contains { $0.reportID == report.id } == true) } }.padding(24).frame(width: 680, height: 600).foregroundStyle(BeeStyle.text).background(BeeStyle.surface).beeAppearance().sheet(item: $detail) { OperationDetailSheet(context: $0) }
    } }
}
struct ReportCalculationKey: Equatable {
    var databaseID: UUID?
    var revision: UInt64
    var report: Report
}

struct ReportDisplay: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @Environment(\.beeAppearance) private var appearance
    @EnvironmentObject var model: AppModel; var report: Report
    var onDetail: (([UUID], String, Filters) -> Void)?
    var onAccount: ((UUID) -> Void)?
    @State private var result: Result<[ReportRow], Error>?
    private var calculationKey: ReportCalculationKey {
        ReportCalculationKey(databaseID: model.db?.id, revision: model.db?.revision ?? 0, report: report)
    }
    private func displayTitle(_ row: ReportRow) -> String {
        if report.grouping == .day, let day = try? Day(row.title) { return CalendarDays.label(day) }
        if report.grouping == .month, let day = try? Day(row.title + "-01") {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.timeZone = Day.calendar.timeZone; formatter.dateFormat = "LLLL yyyy"
            return formatter.string(from: day.date)
        }
        return row.title
    }
    var body: some View {
        content.task(id: calculationKey) {
            result = nil
            guard let snapshot = model.db else { result = .failure(BudgetError.locked); return }
            let candidate = report, key = calculationKey
            let worker = Task.detached(priority: .userInitiated) { Result { try Reports.rows(candidate, db: snapshot) } }
            let calculated = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, key == calculationKey else { return }
            result = calculated
        }
    }
    @ViewBuilder private var content: some View {
        if [.financialPlan, .depositYield].contains(report.dataset) { Text("Прогноз по введённым условиям. Частичные суммы могут не учитывать неизвестные ставки, налоги или курсы.").beeFont(.caption).foregroundStyle(BeeStyle.warning) }
        switch result {
        case .none: ProgressView("Рассчитываем отчёт…")
        case .some(.failure(let e)): Text(e.localizedDescription).foregroundStyle(BeeStyle.negative)
        case .some(.success(let rows)):
            if rows.isEmpty { EmptyState(title: "Нет данных", detail: "В выбранном периоде и фильтрах нет подходящих операций.") }
            else { VStack(alignment: .leading, spacing: 10) {
                if let v = [Dataset.balances, .debt].contains(report.dataset) && report.grouping != .account ? rows.last?.value : try? Reports.total(rows) { Group { if report.metric == .count { Text("\(v.known) операций").beeFont(.title3.bold()) } else { PartialValue(value: v, currency: report.currency, onMissingOperations: { ids in if let onDetail { onDetail(ids, report.name + " · без курса", report.filters) } else { model.showOperations(ids, title: report.name + " · без курса", filters: report.filters) } }) } } }
                if report.presentation != .table {
                    let colors = [BeeStyle.expense, BeeStyle.positive, BeeStyle.warning, BeeStyle.negative, BeeStyle.controlAccent, BeeStyle.muted]
                    Chart(rows) { row in
                    let value = Double(row.value.known) / (report.metric == .count ? 1 : pow(10, Double((try? Currency.get(report.currency).scale) ?? 2)))
                    if report.presentation == .bars { BarMark(x: .value("Группа", displayTitle(row)), y: .value("Значение", value)).foregroundStyle(BeeStyle.expense) }
                    else if report.presentation == .line { LineMark(x: .value("Дата", displayTitle(row)), y: .value("Значение", value)).foregroundStyle(BeeStyle.expense); PointMark(x: .value("Дата", displayTitle(row)), y: .value("Значение", value)) }
                    else { SectorMark(angle: .value("Значение", value), innerRadius: .ratio(0.65)).foregroundStyle(by: .value("Группа", displayTitle(row))) }
                    }.chartForegroundStyleScale(domain: rows.map(displayTitle), range: rows.indices.map { colors[$0 % colors.count] })
                        .chartLegend(.hidden)
                        .chartXAxis { AxisMarks { axis in AxisValueLabel { if let label = axis.as(String.self) { Text(label).beeFont(.caption).foregroundStyle(BeeStyle.muted) } } } }.chartYAxis { AxisMarks { axis in AxisGridLine().foregroundStyle(BeeStyle.line.opacity(0.25)); AxisValueLabel { if let number = axis.as(Double.self) { Text(number.formatted(.number.precision(.fractionLength(0)))).beeFont(.caption).foregroundStyle(BeeStyle.muted) } } } }.frame(height: 220 * appearance.scale)
                    if report.presentation == .ring {
                        WrappingLayout(spacing: 12) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                HStack(spacing: 6) {
                                    Circle().fill(colors[index % colors.count]).frame(width: 10 * appearance.scale, height: 10 * appearance.scale).accessibilityHidden(true)
                                    Text(displayTitle(row)).beeFont(.caption).foregroundStyle(BeeStyle.muted)
                                }
                            }
                        }
                    }
                }
                ForEach(rows) { row in HStack { Text(displayTitle(row)); Spacer(); Text(report.metric == .count ? String(row.value.known) : BeeFormat.valuation(row.value, currency: report.currency)).monospacedDigit(); Button("Детали") { if !row.operationIDs.isEmpty { if let onDetail { onDetail(row.operationIDs, report.name + " · " + displayTitle(row), report.filters) } else { model.showOperations(row.operationIDs, title: report.name + " · " + displayTitle(row), filters: report.filters) } } else if let id = row.accountIDs.first { if let onAccount { onAccount(id) } else { model.openHistory(id) } } }.controlSize(.small) } }
            } }
        }
    }
}
