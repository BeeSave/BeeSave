import SwiftUI
import BudgetCore
import BudgetPresentation

struct OperationsWorkspace: View {
    @EnvironmentObject var model: AppModel
    private let route = WorkspaceRoute(.operations)
    private var selection: Binding<JournalSelection> { Binding(get: { model.navigation.context(for: route).journal }, set: { value in model.updateWorkspaceContext(route) { $0.journal = value } }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspacePages(title: "Разделы операций", pages: OperationsPage.allCases, selected: model.navigation.current.operationsPage, label: { $0.title }) { page in model.navigate(WorkspaceRoute(.operations, operations: page)) }.padding(.horizontal, 26).padding(.vertical, 14)
            switch model.navigation.current.operationsPage {
            case .journal:
                JournalWorkspace(selection: selection, route: route)
            case .budgets: BudgetsView()
            case .reports: SavedReportsView()
            case .references: ReferencesView()
            }
        }
    }
}

struct JournalWorkspace: View {
    @Binding var selection: JournalSelection
    var route: WorkspaceRoute
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BeePicker("Вид операции", selection: $selection) { ForEach(JournalSelection.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 330).padding(.horizontal, 26)
            OperationsView(kind: selection.kind, workspaceRoute: route).id(selection)
        }
    }
}

struct SavedReportsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { if let db = model.db {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: "Отчёты") { Button("Создать отчёт", systemImage: "plus") { model.sheet = SheetRoute(kind: .report) }.buttonStyle(BeePrimaryStyle()) }
            if db.reports.isEmpty { EmptyState(title: "Сохранённых отчётов пока нет", detail: "Выберите данные, фильтры и представление в конструкторе.").beeCard() }
            ForEach(db.reports) { report in
                HStack { Button(report.name) { model.sheet = SheetRoute(kind: .reportView, entityID: report.id) }; Spacer(); Text(report.currency).beeFont(.caption); Button("Изменить") { model.sheet = SheetRoute(kind: .report, entityID: report.id) }; Button("Удалить", role: .destructive) { if confirmDeletion(report.name, consequence: "Операции сохранятся. Блоки этого отчёта будут удалены из Обзора.") { model.perform { db in db.reports.removeAll { $0.id == report.id }; db.dashboard.removeAll { $0.reportID == report.id } } } } }.beeCard()
            }
        }.padding(26).background(WorkspaceScrollMemory(route: WorkspaceRoute(.operations, operations: .reports))) }
    } }
}
