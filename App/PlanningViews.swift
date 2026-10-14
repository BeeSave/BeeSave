import SwiftUI
import Charts
import BudgetCore
import BudgetPresentation

struct PlanningView: View {
    @EnvironmentObject var model: AppModel
    @State private var reserveOpen = false
    @State private var distributionOpen = false
    private var page: PlanPage { model.navigation.current.planPage }
    var body: some View { if let db = model.db {
        VStack(alignment: .leading, spacing: 0) {
            WorkspacePages(title: "Страницы плана", pages: PlanPage.allCases, selected: page, label: { $0.title }) { model.navigate(WorkspaceRoute(.plan, plan: $0)) }.padding(.horizontal, 26).padding(.vertical, 14)
            if page == .calendar { PlanningCalendarWorkspace() }
            else { ScrollView { VStack(alignment: .leading, spacing: 20) {
                SectionHeading(title: page.title) {
                    switch page {
                    case .regular: Button("Добавить доход", systemImage: "plus") { model.newPlanFlow(.income) }.buttonStyle(BeePrimaryStyle())
                    case .goals: Button("Новая цель", systemImage: "plus") { model.sheet = SheetRoute(kind: .savingsGoal) }.buttonStyle(BeePrimaryStyle())
                    case .taxes: Button("Новый налоговый расчёт", systemImage: "plus") { model.sheet = SheetRoute(kind: .taxProfile) }.buttonStyle(BeePrimaryStyle())
                    case .scenarios: Button("Сохранить базовый сценарий") { model.changePlanning(.scenario(PlanScenario(title: "План \(Day.today)", snapshotRevision: db.revision ?? 0, flows: db.planningData.flows, reserve: db.planningData.reserve, currency: db.planningData.reserveCurrency))) }.buttonStyle(BeePrimaryStyle())
                    case .calendar: EmptyView()
                    }
                }
                switch page {
                case .regular:
                    Text("Доход, стоимость жизни и обязательные регулярные выплаты. Подробный учёт покупок необязателен.").foregroundStyle(BeeStyle.backgroundMuted)
                    WrappingLayout(spacing: 12) {
                        Button("Добавить стоимость жизни") { model.newPlanFlow(.living) }
                        Button("Добавить регулярный расход") { model.newPlanFlow(.payment) }
                        Button("Изменить резерв") { reserveOpen = true }
                        Button("Распределить доход") { distributionOpen = true }
                    }
                    if db.planningData.flows.isEmpty { EmptyState(title: "Начните с дохода и стоимости жизни", detail: "Неизвестные суммы можно оставить для уточнения.").beeCard() }
                    ForEach(db.planningData.flows) { PlanningFlowCard(flow: $0) }
                    DisclosureGroup("Прогнозные валютные курсы") { PlanningRatesView() }
                case .goals:
                    if db.planningData.goals.isEmpty { EmptyState(title: "На что хотите накопить?", detail: "Укажите цель и дату — приложение рассчитает необходимый темп.").beeCard() }
                    ForEach(db.planningData.goals) { goal in VStack(alignment: .leading, spacing: 12) {
                        HStack { Text(goal.title).beeFont(.headline); Spacer(); Button("Изменить") { model.sheet = SheetRoute(kind: .savingsGoal, entityID: goal.id) } }
                        Text(BeeFormat.money(goal.allocated, currency: goal.currency) + " из " + BeeFormat.money(goal.target, currency: goal.currency)).beeFont(.title3)
                        ProgressView(value: min(1, Double(goal.allocated) / Double(max(1, goal.target))))
                        if let p = try? PlanningEngine.savings(goal) { Text("Нужно в месяц: " + BeeFormat.money(p.requiredMonthly, currency: goal.currency)); Text(p.achievableOn.map { "При выбранном темпе: " + CalendarDays.label($0, full: true) } ?? "Темп пополнения пока не задан").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
                    }.beeCard() }
                case .taxes:
                    Text("Россия · трудовой НДФЛ, жильё и ипотечные проценты, лечение и обучение · 2025/2026. Налоги бизнеса задаются в проекте вручную.").beeFont(.caption).foregroundStyle(BeeStyle.backgroundMuted)
                    if db.planningData.taxes.isEmpty { EmptyState(title: "Налоговых расчётов пока нет", detail: "Выберите год и профиль. Оценка возврата не считается подтверждённым поступлением.").beeCard() }
                    ForEach(db.planningData.taxes) { tax in Button { model.sheet = SheetRoute(kind: .taxProfile, entityID: tax.id) } label: { HStack { VStack(alignment: .leading) { Text(tax.title).beeFont(.headline); Text(String(tax.year) + " · " + tax.stage.title).beeFont(.caption) }; Spacer(); if let r = db.planningData.taxResults.last(where: { $0.profileID == tax.id }), r.complete { Text("Возможный возврат: " + BeeFormat.money(r.refund ?? 0, currency: "RUB")) } else { Text("Уточните данные") } } }.buttonStyle(BeeRowStyle()).beeCard() }
                case .scenarios:
                    Text("Вариант не меняет фактические операции и условия договора.").beeFont(.caption).foregroundStyle(BeeStyle.backgroundMuted)
                    if db.planningData.scenarios.isEmpty { EmptyState(title: "Сохраните исходный план", detail: "Затем сравните изменения дохода, сроков работ и темпа накопления.").beeCard() }
                    ForEach(db.planningData.scenarios) { PlanningScenarioCard(scenario: $0) }
                case .calendar: EmptyView()
                }
                if let error = model.planningError { Text(error).foregroundStyle(BeeStyle.negative) }
            }.padding(26).background(WorkspaceScrollMemory(route: WorkspaceRoute(.plan, plan: page))) }.id(page) }
        }.sheet(isPresented: $reserveOpen) { PlanningReserveEditor() }
            .sheet(isPresented: $distributionOpen) { PlanningDistributionSheet() }
            .onAppear { if model.planningProjection == nil && !model.financialBusy { model.refreshPlanning() } }
    } }
}
struct PlanningFlowCard: View {
    @EnvironmentObject var model: AppModel
    var flow: PlanFlow
    var body: some View { VStack(alignment: .leading, spacing: 12) {
        Label(flow.title, systemImage: flow.purpose == .income ? "arrow.down.left" : flow.purpose == .living ? "cup.and.saucer" : "calendar")
            .beeFont(.headline).fixedSize(horizontal: false, vertical: true)
        Text(flow.frequency.title + " · " + flow.purpose.title + (flow.enabled ? "" : " · выключен"))
            .beeFont(.caption).foregroundStyle(BeeStyle.muted)
        Text(flow.amount.map { BeeFormat.money($0, currency: flow.currency) } ?? "Уточните сумму").monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
        WrappingLayout(spacing: 12) {
            Button(flow.purpose == .income ? "Отметить поступление" : "Отметить оплату") { model.sheet = SheetRoute(kind: .planFact, entityID: flow.id) }
            Button("Изменить") { model.sheet = SheetRoute(kind: .planFlow, entityID: flow.id) }
        }
    }.frame(maxWidth: .infinity, alignment: .leading).beeCard() }
}
struct PlanningLiquiditySummary: View {
    @EnvironmentObject var model: AppModel
    var body: some View { VStack(alignment:.leading,spacing:12) {
        HStack { Text("Запас для целей").beeFont(.headline); Spacer(); if model.planningBusy { ProgressView().controlSize(.small) } }
        if let p = model.planningProjection {
            HStack(alignment:.top,spacing:24) { VStack(alignment:.leading) { Text("Остаток через 12 месяцев").beeFont(.caption); Text(BeeFormat.money(p.ending,currency:p.currency)).beeFont(.title2.bold()) }; VStack(alignment:.leading) { Text("Минимум в периоде").beeFont(.caption); Text(BeeFormat.money(p.minimum,currency:p.currency)).beeFont(.title2.bold()).foregroundStyle(p.minimum < p.reserve ? BeeStyle.negative : BeeStyle.positive) } }
            if let free = try? p.freeEnding { Text("После резерва и выделения на цели: " + BeeFormat.money(free,currency:p.currency)).foregroundStyle(free < 0 ? BeeStyle.negative : BeeStyle.positive) } else { Text("Свободные средства не оценены: сумма вне поддержанного диапазона").foregroundStyle(BeeStyle.warning) }
            Text("Резерв: " + BeeFormat.money(p.reserve,currency:p.currency) + " · собственные денежные счета").beeFont(.caption).foregroundStyle(BeeStyle.muted)
            if let date = p.firstViolation { Label("Ниже резерва с " + CalendarDays.label(date,full:true),systemImage:"exclamationmark.triangle").foregroundStyle(BeeStyle.warning) }
            if !p.complete { Text("Неполный прогноз: " + p.missing.joined(separator:"; ")).beeFont(.caption).foregroundStyle(BeeStyle.warning) }
        } else { Text(model.planningError ?? "Добавьте данные плана, чтобы оценить предстоящие периоды").foregroundStyle(BeeStyle.muted) }
    }.beeCard() }
}
struct PlanningMonthsView: View {
    var showRows = true
    @EnvironmentObject var model: AppModel
    var body: some View { if let p = model.planningProjection { VStack(alignment:.leading,spacing:14) {
        Text("Предстоящие периоды").beeFont(.headline)
        Chart {
            ForEach(Array(Dictionary(grouping:p.points,by:{ $0.event.date.month }).keys.sorted()),id:\.self) { month in
                if let rows = Dictionary(grouping:p.points,by:{ $0.event.date.month })[month],let last = rows.last {
                    BarMark(x:.value("Месяц",month),y:.value("Остаток",Double(last.balance)/pow(10,Double((try? Currency.get(p.currency).scale) ?? 2)))).foregroundStyle(last.belowReserve ? BeeStyle.expense : BeeStyle.positive)
                }
            }
            RuleMark(y:.value("Резерв",Double(p.reserve)/pow(10,Double((try? Currency.get(p.currency).scale) ?? 2)))).foregroundStyle(BeeStyle.warning).lineStyle(StrokeStyle(lineWidth:1,dash:[4,3]))
        }.frame(height:200).accessibilityLabel("Остаток по месяцам и граница резерва")
        if showRows { ForEach(Array(p.points.prefix(12))) { point in Button { model.openPlanningSource(point.event) } label: { VStack(alignment: .leading, spacing: 8) {
            Text(CalendarDays.label(point.event.date)).beeFont(.caption).foregroundStyle(BeeStyle.muted)
            Text(point.event.title).fixedSize(horizontal: false, vertical: true)
            WrappingLayout(spacing: 12) {
                Text(point.event.remaining.map { BeeFormat.money($0,currency:point.event.currency) } ?? "Уточните сумму").monospacedDigit()
                Text("→ " + BeeFormat.money(point.balance,currency:p.currency)).monospacedDigit().foregroundStyle(point.belowReserve ? BeeStyle.negative : BeeStyle.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(BeeRowStyle()) }
        Button("Весь денежный календарь") { model.navigate(WorkspaceRoute(.plan)) } }
    }.beeCard() } }
}
struct PlanningScenarioCard: View {
    @EnvironmentObject var model: AppModel; var scenario: PlanScenario
    @State private var result: PlanningProjection?; @State private var error: String?; @State private var incomePercent: Int = 100; @State private var projectDelay: Int = 0; @State private var savingsPercent: Int = 100
    var body: some View { VStack(alignment:.leading,spacing:12) {
        HStack { Text(scenario.title).beeFont(.headline); Spacer(); Text(scenario.snapshotRevision == model.db?.revision ? "Текущий срез" : "Исходный срез изменился").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
        Stepper("Доход: \(incomePercent)% от сохранённого плана",value:$incomePercent,in:0...150,step:10)
        Stepper("Сдвиг проектных работ: \(projectDelay) дней",value:$projectDelay,in:-180...730,step:30)
        Stepper("Накопления: \(savingsPercent)% от текущего темпа",value:$savingsPercent,in:0...200,step:10)
        Button("Сравнить с текущим планом") { compare() }
        if let result,let base = model.planningProjection { Text("Остаток: " + BeeFormat.money(result.ending,currency:result.currency) + " · базовый: " + BeeFormat.money(base.ending,currency:base.currency)); Text("Минимум: " + BeeFormat.money(result.minimum,currency:result.currency)); if let free = try? result.freeEnding { Text("После резерва и целей: " + BeeFormat.money(free,currency:result.currency)) }; Text(result.firstViolation.map { "Ниже резерва: " + CalendarDays.label($0,full:true) } ?? "Резерв соблюдён") }
        if let error { Text(error).foregroundStyle(BeeStyle.negative) }
    }.beeCard() }
    private func compare() { guard let db = model.db else { return }; do { var variant = scenario; variant.flows = try scenario.flows.map { flow in var f = flow; if f.purpose == .income,let amount = f.amount { f.amount = try FinanceMath.rounded(Money.divide(Money.multiply(Decimal(amount),Decimal(incomePercent)),100)) }; return f }; variant.projectDelayDays = projectDelay; variant.goalMonthlyPercent = savingsPercent; result = try PlanningEngine.scenario(variant,db:db,through:FinanceMath.addingMonths(.today,12),financeEvents:Array(model.financialEvents.values.joined())); error = nil } catch { self.error = error.localizedDescription } }
}
struct PlanningTrendChart: View {
    var embedded = false
    @EnvironmentObject var model: AppModel; @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cash = false; @State private var months = 12; @State private var rows: [PlanningChartPoint] = []; @State private var selected: Date?; @State private var error: String?; @State private var periodDetail: PlanningChartPoint?
    var body: some View { VStack(alignment:.leading,spacing:14) {
        if !embedded { Text("Доходы и расходы").beeFont(.headline) }
        WrappingLayout(spacing: 12) {
            BeePicker("Горизонт",selection:$months) { Text("6 месяцев").tag(6); Text("12 месяцев").tag(12); Text("24 месяца").tag(24) }
            BeePicker("Показатель",selection:$cash) { Text("Доходы / расходы").tag(false); Text("Движение денег").tag(true) }.beePickerStyle(.segmented)
        }
        WrappingLayout(spacing:12) { Label("Доходы",systemImage:"circle.fill").foregroundStyle(BeeStyle.positive); Label("Расходы",systemImage:"square.fill").foregroundStyle(BeeStyle.expense); Text("Пунктир — прогноз · вертикальная линия — сегодня").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
        if rows.isEmpty { EmptyState(title:"Пока нет данных для графика",detail:"Добавьте доход, расход или финансовый план. Будущие суммы появятся из вашего плана.") } else { Chart {
            ForEach(rows.filter { $0.missing.isEmpty }) { row in
                LineMark(x:.value("Дата",row.date.date),y:.value("Доход",Double(row.income)/pow(10,Double((try? Currency.get(model.db?.settings.baseCurrency ?? "RUB").scale) ?? 2))),series:.value("Ряд",(row.forecast ? "Доход · прогноз" : "Доход · факт") + gapSegment(row))).foregroundStyle(BeeStyle.positive).symbol(.circle).symbolSize(16).lineStyle(StrokeStyle(lineWidth:2.5,dash:row.forecast ? [5,4] : [])).interpolationMethod(.monotone)
                LineMark(x:.value("Дата",row.date.date),y:.value("Расход",Double(row.expense)/pow(10,Double((try? Currency.get(model.db?.settings.baseCurrency ?? "RUB").scale) ?? 2))),series:.value("Ряд",(row.forecast ? "Расход · прогноз" : "Расход · факт") + gapSegment(row))).foregroundStyle(BeeStyle.expense).symbol(.square).symbolSize(16).lineStyle(StrokeStyle(lineWidth:2.5,dash:row.forecast ? [5,4] : [])).interpolationMethod(.monotone)
            }
            RuleMark(x:.value("Сегодня",Day.today.date)).foregroundStyle(BeeStyle.muted).accessibilityLabel("Сегодня")
        }.frame(height:230).chartXSelection(value:$selected).animation(disableMotion ? nil : .easeInOut(duration:0.3),value:cash) }
        if let selected,let row = rows.min(by:{ abs($0.date.date.timeIntervalSince(selected)) < abs($1.date.date.timeIntervalSince(selected)) }) { Text("\(row.date.month): доход \(BeeFormat.money(row.income,currency:model.db?.settings.baseCurrency ?? "RUB")), расход \(BeeFormat.money(row.expense,currency:model.db?.settings.baseCurrency ?? "RUB"))\(row.forecast ? " · прогноз" : " · факт")").beeFont(.caption) }
        DisclosureGroup("Точные суммы по периодам") { ForEach(rows) { row in Button { periodDetail = row } label: { HStack { Text(row.date.month + (row.forecast ? " · прогноз" : " · факт")); Spacer(); Text(row.missing.isEmpty ? BeeFormat.money(row.income,currency:model.db?.settings.baseCurrency ?? "RUB") + " / " + BeeFormat.money(row.expense,currency:model.db?.settings.baseCurrency ?? "RUB") : "Неполная оценка") } }.buttonStyle(BeeRowStyle()) } }
        Text(cash ? "Внешнее движение собственных денежных счетов; займы и погашение тела включены." : "Переводы, тело долга и нейтральные корректировки исключены. Полные выплаты видны в календаре ликвидности.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        if let error { Text(error).beeFont(.caption).foregroundStyle(BeeStyle.warning) }
    }.modifier(PlanningChartSurface(embedded:embedded)).sheet(item:$periodDetail) { row in PlanningChartPeriodDetail(row:row,cash:cash) }.task(id:"\(model.db?.id.uuidString ?? "locked").\(model.db?.revision ?? 0).\(cash).\(months).\(model.planningRows.count)") { await calculate() } }
    private var disableMotion: Bool {
        #if DEBUG && UI_SMOKE
        return reduceMotion || model.previewReduceMotion
        #else
        return reduceMotion
        #endif
    }
    private func gapSegment(_ point:PlanningChartPoint) -> String { "." + String(rows.filter { $0.date < point.date && !$0.missing.isEmpty }.count) }
    private func calculate() async {
        guard let snapshot = model.db else { rows = []; return }
        guard snapshot.operations.contains(where:{ $0.kind.isFlow }) || !snapshot.planningData.flows.isEmpty || !snapshot.financeData.contracts.isEmpty || snapshot.projects.contains(where:{ !($0.details?.costs.isEmpty ?? true) || $0.details?.loan != nil }) else { rows = []; error = nil; return }
        let cash = cash,months = months,financial = Array(model.financialEvents.values.joined())
        do { let worker = Task.detached { let end = try FinanceMath.addingMonths(Day.today,months).lastOfMonth; let forecast = try PlanningEngine.events(db:snapshot,from:.today,through:end,financeEvents:financial); return try PlanningCharts.monthly(db:snapshot,from:FinanceMath.addingMonths(Day.today.firstOfMonth,-6),through:end,cash:cash,forecast:forecast) }; let result = try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() }); guard !Task.isCancelled,model.db?.id == snapshot.id,model.db?.revision == snapshot.revision else { return }; rows = result; error = result.contains { !$0.missing.isEmpty } ? "Есть периоды без полной оценки — линии прерваны" : nil }
        catch is CancellationError {} catch { guard !Task.isCancelled, model.db?.id == snapshot.id, model.db?.revision == snapshot.revision else { return }; rows = []; self.error = error.localizedDescription }
    }
}

struct IncomeDistributionView: View {
    var onDirty: (Bool) -> Void = { _ in }
    var onApply: () -> Void = {}
    @EnvironmentObject var model: AppModel
    @State private var income: Int64 = 0; @State private var rules: [IncomeAllocationRule] = []; @State private var loaded = false; @State private var result: [Int64]?; @State private var error: String?
    @State private var revision: UInt64?
    @State private var originalIncome: Int64 = 0
    @State private var originalRules: Data?
    private var dirty: Bool { loaded && (income != originalIncome || (try? JSONEncoder().encode(rules)) != originalRules) }
    var body: some View { DisclosureGroup("Распределить регулярный чистый доход", isExpanded: .constant(true)) { VStack(alignment:.leading,spacing:14) {
        PlanningMoneyField(title:"Доход после налоговых удержаний на период",amount:$income,currency:model.db?.settings.baseCurrency ?? "RUB")
        ForEach(rules.indices,id:\.self) { i in HStack {
            TextField("Назначение",text:$rules[i].title).textFieldStyle(BeeTextFieldStyle())
            Toggle("%",isOn:Binding(get:{ rules[i].percent != nil },set:{ v in rules[i].fixed = v ? nil : 0; rules[i].percent = v ? "0" : nil }))
            if rules[i].percent != nil { TextField("Процент",text:Binding(get:{ rules[i].percent ?? "0" },set:{ rules[i].percent = $0 })).textFieldStyle(BeeTextFieldStyle()).frame(maxWidth:120) }
            else { PlanningMoneyField(title:"Сумма",amount:Binding(get:{ rules[i].fixed ?? 0 },set:{ rules[i].fixed = $0 }),currency:model.db?.settings.baseCurrency ?? "RUB") }
        } }
        WrappingLayout(spacing: 12) { Button("Добавить назначение") { rules.append(IncomeAllocationRule(title:"",fixed:0)) }; Button("Рассчитать") { calculate() }; Button("Принять распределение") { apply() }.buttonStyle(BeePrimaryStyle()) }
        if let result { ForEach(Array(rules.enumerated()),id:\.element.id) { i,rule in if i < result.count { HStack { Text(rule.title); Spacer(); Text(BeeFormat.money(result[i],currency:model.db?.settings.baseCurrency ?? "RUB")) } } }; Text("Свободно для других целей: " + BeeFormat.money(income-result.reduce(0,+),currency:model.db?.settings.baseCurrency ?? "RUB")) }
        if let error { Text(error).foregroundStyle(BeeStyle.negative) }
        Text("Проценты берутся от указанного чистого дохода. Принятие сохраняет план распределения и не создаёт списаний.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
    }.padding(.top,12) }.beeCard().onAppear { if !loaded { income = model.db?.planningData.distributionIncome ?? 0; rules = model.db?.planningData.allocationRules ?? []; revision = model.db?.revision ?? 0; originalIncome = income; originalRules = try? JSONEncoder().encode(rules); loaded = true } }
        .onChange(of: dirty) { _, value in onDirty(value) }
    }
    private func apply() { do { try model.savePlanning(.distribution(income, rules), expectedRevision: revision); originalIncome = income; originalRules = try? JSONEncoder().encode(rules); onDirty(false); onApply() } catch { self.error = error.localizedDescription } }
    private func calculate() { do { result = try IncomeDistribution.calculate(netIncome:income,rules:rules); error = nil } catch { self.error = error.localizedDescription; result = nil } }
}
struct PlanningCalendarList: View {
    @EnvironmentObject var model: AppModel
    @State private var from = Day.today; @State private var through = Day.today.adding(365); @State private var rows: [PlannedOccurrence] = []; @State private var error: String?; @State private var includeConditional = false
    private let route = WorkspaceRoute(.plan)
    var body: some View { DisclosureGroup("Общий денежный календарь: жизнь, проекты, обязательства и поступления", isExpanded: .constant(true)) {
        VStack(alignment:.leading,spacing:14) {
            HStack { PlanningDateField(title:"С",day:$from); PlanningDateField(title:"По",day:$through) }
            Toggle("Включить условные сценарные потоки",isOn:$includeConditional)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.title).beeFont(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(CalendarDays.label(row.date,full:true) + " · " + row.certainty.title + " · " + row.purpose.title).beeFont(.caption).foregroundStyle(BeeStyle.muted).fixedSize(horizontal: false, vertical: true)
                    WrappingLayout(spacing: 12) {
                        Text(row.remaining.map { BeeFormat.money($0,currency:row.currency) } ?? "Уточните сумму").foregroundStyle(row.income ? BeeStyle.positive : BeeStyle.expense)
                        Button("Открыть") { model.openPlanningSource(row) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                Divider()
            }
            if let error { Text(error).foregroundStyle(BeeStyle.warning) }
        }.padding(.top,12)
    }.beeCard()
        .onAppear { let context = model.navigation.context(for: route); from = context.filters.start ?? .today; through = context.filters.end ?? .today.adding(365); includeConditional = context.calendarConditional }
        .onChange(of: from) { _, value in model.updateWorkspaceContext(route) { $0.filters.start = value } }
        .onChange(of: through) { _, value in model.updateWorkspaceContext(route) { $0.filters.end = value } }
        .onChange(of: includeConditional) { _, value in model.updateWorkspaceContext(route) { $0.calendarConditional = value } }
        .task(id:"\(model.db?.id.uuidString ?? "locked").\(from).\(through).\(includeConditional).\(model.db?.revision ?? 0).\(model.planningRows.count)") { await calculate() } }
    private func calculate() async { guard let db = model.db else { rows = []; return }; let from = from,through = through,conditional = includeConditional,financial = Array(model.financialEvents.values.joined()); do { let worker = Task.detached { try PlanningEngine.events(db:db,from:from,through:through,financeEvents:financial,includeConditional:conditional) }; let result = try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() }); guard !Task.isCancelled,model.db?.id == db.id,model.db?.revision == db.revision else { return }; rows = result; error = nil } catch is CancellationError {} catch { guard !Task.isCancelled, model.db?.id == db.id, model.db?.revision == db.revision else { return }; rows = []; self.error = error.localizedDescription } }
}

struct PlanningRatesView: View {
    @EnvironmentObject var model:AppModel
    @State private var base = "USD"; @State private var quote = "RUB"; @State private var rate = ""; @State private var date = Day.today
    var body: some View { DisclosureGroup("Курсы для планирования — отдельные допущения") { VStack(alignment:.leading,spacing:14) {
        HStack { CurrencyPicker(title:"Из",selection:$base); CurrencyPicker(title:"В",selection:$quote) }
        FormField(title:"1 \(base) = X \(quote)") { TextField("Прогнозный курс",text:$rate).textFieldStyle(BeeTextFieldStyle()) }
        PlanningDateField(title:"Применять с",day:$date)
        Button("Сохранить допущение") { model.changePlanning(.forecastRate(FXRate(base:base,quote:quote,rate:rate.replacingOccurrences(of:",",with:"."),date:date,provider:"Прогноз: выбран пользователем"))) }
        Button("Использовать текущие курсы как допущение") { let forecasts = (model.db?.rates ?? []).map { r in var forecast = r; forecast.provider = "Прогноз из справочного курса " + r.provider; return forecast }; model.changePlanning(.forecastRates(forecasts)) }
        ForEach(model.db?.planningData.forecastRates ?? [],id:\.id) { r in Text("1 \(r.base) = \(r.rate) \(r.quote) · с \(r.date.rawValue)").beeFont(.caption) }
        Text("Изменение прогнозного курса пересчитывает будущее, сохраняя исторические снимки операций.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
    }.padding(.top,12) }.beeCard().onAppear { quote = model.db?.settings.baseCurrency ?? "RUB"; base = quote == "USD" ? "RUB" : "USD" } }
}

private struct PlanningChartSurface: ViewModifier {
    var embedded: Bool
    @ViewBuilder func body(content: Content) -> some View { if embedded { content } else { content.beeCard() } }
}

private struct PlanningChartPeriodDetail: View {
    @EnvironmentObject var model: AppModel; @Environment(\.dismiss) private var dismiss
    var row: PlanningChartPoint; var cash: Bool
    @State private var events: [PlannedOccurrence] = []; @State private var error: String?
    var body: some View { VStack(alignment:.leading,spacing:16) {
        HStack { Text(row.date.month + (row.forecast ? " · прогноз" : " · факт")).beeFont(.title2); Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction) }
        ScrollView { VStack(alignment:.leading,spacing:12) {
            if let db = model.db {
                Text(cash ? "Движение денег" : "Доходы и расходы").beeFont(.headline)
                Text("Доход: " + BeeFormat.money(row.income,currency:db.settings.baseCurrency) + " · расход: " + BeeFormat.money(row.expense,currency:db.settings.baseCurrency))
                if !row.missing.isEmpty { Text("Неполная оценка: " + row.missing.joined(separator:"; ")).foregroundStyle(BeeStyle.warning) }
                Text("Учтённые операции").beeFont(.headline)
                let operations = db.operations.filter { $0.date.month == row.date.month && $0.date <= .today && ($0.kind.isFlow || (cash && $0.kind == .transfer)) }
                ForEach(operations) { operation in Button { dismiss(); model.openHistory(operation.accountID) } label: { HStack { Text(operation.date.rawValue); Text(operation.comment.isEmpty ? operation.kind.title : operation.comment); Spacer(); Text(BeeFormat.money(operation.amount,currency:(try? db.account(operation.accountID).currency) ?? db.settings.baseCurrency)) } }.buttonStyle(BeeRowStyle()) }
                if operations.isEmpty { Text("В периоде нет подходящих фактических операций").foregroundStyle(BeeStyle.muted) }
                if row.forecast { Text("Оставшийся план").beeFont(.headline); ForEach(events) { event in Button { dismiss(); model.openPlanningSource(event) } label: { HStack { Text(event.date.rawValue); Text(event.title); Spacer(); Text((cash ? event.remaining : event.reportAmount).map { BeeFormat.money($0,currency:event.currency) } ?? "Уточните сумму") } }.buttonStyle(BeeRowStyle()) } }
            }
            if let error { Text(error).foregroundStyle(BeeStyle.warning) }
        } }
    }.padding(24).beeSheet(width:740,height:680).beeWindow().task {
        guard row.forecast,let db = model.db else { return }
        do { events = try PlanningEngine.events(db:db,from:.today,through:row.date.lastOfMonth,financeEvents:Array(model.financialEvents.values.joined())).filter { max($0.date,.today).month == row.date.month && (!cash || PlanningEngine.affectsPersonal($0,db:db)) } } catch { self.error = error.localizedDescription }
    } }
}
