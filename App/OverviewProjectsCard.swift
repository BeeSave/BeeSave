import SwiftUI
import BudgetCore
import BudgetPresentation

struct OverviewProjectsCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let db = model.db {
            let projects = db.projects.filter { !$0.archived }
            if !projects.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Значимые проекты").beeFont(.headline); Spacer(); Button("Все проекты (\(projects.count))") { model.navigate(WorkspaceRoute(.projects)) } }
                    WrappingLayout(spacing: 18) {
                        ForEach(Array(projects.prefix(3))) { project in
                            Button { model.navigate(WorkspaceRoute(.projects, objectID: project.id)) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.name).beeFont(.headline).fixedSize(horizontal: false, vertical: true)
                                    let details = project.details ?? ProjectDetails()
                                    Text(details.stage.title).beeFont(.caption).foregroundStyle(BeeStyle.muted)
                                    if let summary = try? ProjectEngine.summary(project: project, db: db) {
                                        Text("Оплачено: " + BeeFormat.money(summary.paid, currency: details.currency)).beeFont(.caption)
                                    } else { Text("Уточните данные для оценки").beeFont(.caption).foregroundStyle(BeeStyle.warning) }
                                }.frame(maxWidth: 320, alignment: .leading)
                            }.buttonStyle(BeeRowStyle())
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).beeCard()
            }
        }
    }
}
