import SwiftUI
import BudgetCore

enum ProjectEditTask: Equatable {
    case basic, cost(UUID?), participant(UUID?), fact(UUID?), loan, business, approve
    var title: String {
        switch self {
        case .basic: "Цель и сроки проекта"
        case .cost: "Позиция сметы"
        case .participant: "Условия участия"
        case .fact: "Связать факт проекта"
        case .loan: "Условия ипотеки / кредита"
        case .business: "Модель бизнеса"
        case .approve: "Утвердить план"
        }
    }
}
struct ProjectEditRequest: Identifiable { var id = UUID(); var task: ProjectEditTask }

struct ProjectApprovalEditor: View {
    @EnvironmentObject var model: AppModel
    var projectID: UUID
    @State private var reason = ""
    @State private var revision: UInt64?
    @State private var project: Project?
    var body: some View {
        EditorFrame(title: "Утвердить план проекта", saveTitle: "Утвердить эту версию", canSave: !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, isDirty: !reason.isEmpty, height: 460, save: {
            try model.savePlanning(.approveProject(projectID, reason), reason: reason, expectedRevision: revision)
        }) {
            if let project, let d = project.details {
                Text(project.name).beeFont(.headline)
                Text("\(d.costs.count) позиций · \(d.participants.count) участников · " + d.currency)
                Text("Сохранится новая неизменяемая версия. Утверждение плана не принимает работы и не выполняет платёж.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
                FormField(title: "Основание утверждения") { TextField("Что согласовано и кем", text: $reason).textFieldStyle(BeeTextFieldStyle()) }
            }
        }.onAppear { guard revision == nil else { return }; project = model.db?.projects.first { $0.id == projectID }; revision = model.db?.revision ?? 0 }
    }
}
