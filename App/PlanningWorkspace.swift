import SwiftUI
import BudgetCore
import BudgetPresentation

struct PlanningCalendarWorkspace: View {
    @EnvironmentObject var model: AppModel
    private let route = WorkspaceRoute(.plan)
    private var scope: Binding<CalendarScope> { Binding(get: { model.navigation.current.calendarScope }, set: { value in model.navigate(WorkspaceRoute(.plan, calendar: value)) }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BeePicker("События", selection: scope) { ForEach(CalendarScope.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 400).padding(.horizontal, 26).padding(.bottom, 12)
            switch scope.wrappedValue {
            case .contracts: FinancialCalendarView()
            case .scheduled: ScheduledPaymentsView()
            case .all:
                ScrollView { VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: "Движение денег") { Button("Запланировать платёж", systemImage: "plus") { model.sheet = SheetRoute(kind: .scheduledPayment) }.buttonStyle(BeePrimaryStyle()) }
                    PlanningLiquiditySummary()
                    PlanningMonthsView(showRows: false)
                    PlanningCalendarList()
                    if model.planningRows.isEmpty { EmptyState(title: "Денежный план пока не задан", detail: "Добавьте доход и стоимость жизни на странице «Регулярный план».").beeCard() }
                }.padding(26).background(WorkspaceScrollMemory(route: route)) }
            }
        }
    }
}

struct PlanningReserveEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var amount: Int64 = 0
    @State private var original: Int64 = 0
    @State private var revision: UInt64?
    @State private var currency = "RUB"
    @State private var loaded = false
    var body: some View {
        EditorFrame(title: "Сохраняемый резерв", isDirty: loaded && amount != original, height: 350, save: {
            try model.savePlanning(.reserve(amount, currency), expectedRevision: revision)
        }) {
            PlanningMoneyField(title: "Мой резерв", amount: $amount, currency: currency)
            Text("Это граница остатка, а не расход. Изменение не создаёт денежную операцию.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        }.onAppear { guard !loaded, let db = model.db else { return }; currency = db.planningData.reserveCurrency; amount = db.planningData.reserve; original = amount; revision = db.revision ?? 0; loaded = true }
    }
}

struct PlanningDistributionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var dirty = false
    @State private var discard = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Распределить доход").beeFont(.title2); Spacer(); Button("Закрыть") { if dirty { discard = true } else { dismiss() } }.keyboardShortcut(.cancelAction) }
            ScrollView { IncomeDistributionView(onDirty: { dirty = $0 }, onApply: { dismiss() }) }
        }.padding(24).beeSheet(width: 680, height: 600).modifier(UpdateFormGuard(active: true)).beeAppearance().interactiveDismissDisabled(dirty)
            .background(EditorEscapeGuard { if dirty { discard = true } else { dismiss() } })
            .confirmationDialog("Есть несохранённые изменения распределения", isPresented: $discard) {
                Button("Отказаться", role: .destructive) { dismiss() }
                Button("Продолжить редактирование", role: .cancel) {}
            }
    }
}
