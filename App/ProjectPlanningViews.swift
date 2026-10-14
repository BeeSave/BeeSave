import SwiftUI
import BudgetCore
import BudgetPresentation

struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    @State private var edit: ProjectEditRequest?
    private let rootRoute = WorkspaceRoute(.projects)
    private var search: Binding<String> { Binding(get: { model.navigation.context(for: rootRoute).search }, set: { value in model.updateWorkspaceContext(rootRoute) { $0.search = value } }) }
    private var archived: Binding<Bool> { Binding(get: { model.navigation.context(for: rootRoute).archived }, set: { value in model.updateWorkspaceContext(rootRoute) { $0.archived = value } }) }
    var body: some View { if let db = model.db { VStack(alignment:.leading,spacing:0) {
        if let id = model.planningProjectID,let project = db.projects.first(where:{ $0.id == id }) {
            WorkspacePages(title: "Задачи проекта", pages: ProjectPage.allCases, selected: model.navigation.current.projectPage, label: { $0.title }) { model.navigate(WorkspaceRoute(.projects, project: $0, objectID: id)) }.padding(.horizontal, 26).padding(.vertical, 14)
            ScrollView { VStack(alignment: .leading, spacing: 20) {
                SectionHeading(title:project.name) { Button("Все проекты",systemImage:"arrow.left") { model.planningProjectID = nil }; Button("Изменить цель") { edit = ProjectEditRequest(task: .basic) } }
                ProjectWorkspace(project:project, edit: { edit = ProjectEditRequest(task: $0) })
            }.padding(26).background(WorkspaceScrollMemory(route: model.navigation.current)) }.id(model.navigation.current)
        } else {
            ScrollView { VStack(alignment: .leading, spacing: 20) {
            SectionHeading(title:"Проекты") { Button("Новый проект",systemImage:"plus") { model.sheet = SheetRoute(kind:.project) }.buttonStyle(BeePrimaryStyle()) }
            HStack { TextField("Найти проект",text:search).textFieldStyle(BeeTextFieldStyle()); Toggle("Показывать архив",isOn:archived) }
            if db.projects.isEmpty { EmptyState(title:"Начните со значимой цели",detail:"Ипотека, ремонт, строительство или бизнес: оцените затраты, сроки и свой вклад.").beeCard() }
            LazyVGrid(columns:[GridItem(.adaptive(minimum:320,maximum:560))],spacing:18) {
                ForEach(db.projects.filter { (archived.wrappedValue || !$0.archived) && (search.wrappedValue.isEmpty || $0.name.localizedCaseInsensitiveContains(search.wrappedValue)) }) { project in Button { model.planningProjectID = project.id } label: { VStack(alignment:.leading,spacing:12) {
                    let d = project.details ?? ProjectDetails()
                    Label(project.name,systemImage:d.type.icon).beeFont(.headline)
                    Text(d.type.title + " · " + d.stage.title).beeFont(.caption).foregroundStyle(BeeStyle.muted)
                    if let summary = try? ProjectEngine.summary(project:project,db:db) { if let loan = d.loan { Text("Сумма займа: " + BeeFormat.money(loan.principal,currency:d.currency)).beeFont(.title3) } else if let business = d.business { Text("Стартовые вложения: " + BeeFormat.money(business.initial,currency:d.currency)).beeFont(.title3) } else { Text("Прогноз: " + BeeFormat.money(summary.forecast,currency:d.currency)).beeFont(.title3) }; Text("Оплачено: " + BeeFormat.money(summary.paid,currency:d.currency)).beeFont(.caption) }
                    if let due = d.dueOn { Text(CalendarDays.label(due,full:true)).beeFont(.caption) }
                    if d.migrated { Text("Перенесённый проект · уточните план").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
                }.frame(maxWidth:.infinity,alignment:.leading).beeCard() }.buttonStyle(.plain)
                    .contextMenu {
                        Button("Изменить цель") { model.sheet = SheetRoute(kind: .project, entityID: project.id) }
                        Button(project.archived ? "Вернуть из архива" : "Архивировать") { var value = project; value.archived.toggle(); model.changePlanning(.project(value)) }
                        Button("Удалить", role: .destructive) { if confirmDeletion(project.name, consequence: "Проект со ссылками можно только архивировать.") { model.perform { try Ledger.deleteProject(project.id, in: &$0) } } }
                    }
                }
            }
            }.padding(26).background(WorkspaceScrollMemory(route: rootRoute)) }
        }
    }.sheet(item:$edit) { request in if let id = model.planningProjectID { if request.task == .approve { ProjectApprovalEditor(projectID: id) } else { ProjectDetailsEditor(id:id, task:request.task) } } } } }
}
struct ProjectWorkspace: View {
    @EnvironmentObject var model: AppModel; var project: Project; var edit: (ProjectEditTask) -> Void
    private var page: ProjectPage { model.navigation.current.projectPage }
    @State private var myFlow = false; @State private var reason = ""; @State private var prepay: Int64 = 0; @State private var prepayDate = Day.today.adding(30); @State private var loanRows: [ProjectLoanRow] = []; @State private var loanError: String?
    var body: some View { if let db = model.db { let d = project.details ?? ProjectDetails()
        VStack(alignment:.leading,spacing:20) {
            HStack { Label(d.type.title,systemImage:d.type.icon); Text(d.stage.title).foregroundStyle(BeeStyle.muted); Spacer(); if let date = d.dueOn { Text(CalendarDays.label(date,full:true)) } }
            if !project.description.isEmpty { Text(project.description) }
            if page == .overview, let summary = try? ProjectEngine.summary(project:project,db:db) {
                if d.loan == nil && d.business == nil { LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 18) { projectNumber("Оплачено",myFlow ? summary.userPaid : summary.paid,currency:d.currency); projectNumber("Прогноз всего проекта",summary.forecast,currency:d.currency); if d.target > 0 { projectNumber("Текущая цель",d.target,currency:d.currency) } }.beeCard() }
                Toggle("Мой денежный поток",isOn:$myFlow).toggleStyle(.switch)
                Text("Договоры: \(BeeFormat.money(summary.contractedRemaining,currency:d.currency)) · оставшиеся работы: \(BeeFormat.money(summary.uncommitted,currency:d.currency)) · резерв: \(BeeFormat.money(summary.reserve,currency:d.currency))").beeFont(.caption).foregroundStyle(BeeStyle.backgroundMuted)
            } else if page == .overview { Text("Не удалось оценить проект. Проверьте исторические валютные курсы.").foregroundStyle(BeeStyle.warning) }
            if page == .overview {
                WrappingLayout(spacing: 12) {
                    Button("Открыть план и смету") { model.navigate(WorkspaceRoute(.projects, project: .costs, objectID: project.id)) }.buttonStyle(BeePrimaryStyle())
                    Button("Факт и платежи") { model.navigate(WorkspaceRoute(.projects, project: .payments, objectID: project.id)) }
                }
                if let loan = d.loan { Text("Займ: " + BeeFormat.money(loan.principal, currency: d.currency) + " · \(loan.annualPercent)% · \(loan.months) месяцев").beeCard() }
                if let business = d.business, let result = try? ProjectEngine.business(business) { Text("Месячный результат бизнеса: " + BeeFormat.money(result.monthlyResult, currency: d.currency)).beeCard() }
                Text("Прогноз не создаёт договор или денежную операцию. Полные условия доступны на странице плана.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
            }
            if page == .participants {
                Button("Добавить участника", systemImage: "plus") { edit(.participant(nil)) }.buttonStyle(BeePrimaryStyle())
                if d.participants.isEmpty { EmptyState(title: "Участники пока не заданы", detail: "Добавьте свой профиль и согласованные вклады.").beeCard() }
                if !d.participants.isEmpty { ProjectIncomeCalculator(details:d) }
                VStack(alignment:.leading,spacing:12) { Text("Участники").beeFont(.headline); ForEach(d.participants) { party in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(party.name + (party.isUser ? " · я" : "")).beeFont(.headline); Text(party.role).beeFont(.caption).foregroundStyle(BeeStyle.muted)
                        Text("Вклад: " + BeeFormat.money(party.promised,currency:d.currency) + " · " + (party.confirmed ? "Подтверждён" : "План"))
                        Button("Условия участия") { edit(.participant(party.id)) }
                    }.padding(.vertical, 8)
                } }.beeCard()
            }
            if page == .costs {
                if d.type == .mortgage { Button("Условия ипотеки / кредита") { edit(.loan) }.buttonStyle(BeePrimaryStyle()) }
                else if d.type == .business { Button("Условия модели бизнеса") { edit(.business) }.buttonStyle(BeePrimaryStyle()) }
                else { Button("Добавить позицию сметы", systemImage: "plus") { edit(.cost(nil)) }.buttonStyle(BeePrimaryStyle()) }
                if d.costs.isEmpty && d.loan == nil && d.business == nil { EmptyState(title: "Смета пока не задана", detail: "Разделите план по работам и срокам; принятые договоры отмечаются отдельно.").beeCard() }
                ForEach(d.costs) { cost in VStack(alignment: .leading, spacing: 10) {
                    Text(cost.title).beeFont(.headline); Text(cost.stage + " · " + (cost.contracted ? "Договор" : "Оценка")).beeFont(.caption).foregroundStyle(BeeStyle.muted)
                    WrappingLayout(spacing: 12) { Text(CalendarDays.label(cost.dueOn)); Text(BeeFormat.money(cost.amount,currency:d.currency)); if let paid = try? ProjectEngine.paid(cost:cost,details:d,db:db) { Text("Факт: " + BeeFormat.money(paid,currency:d.currency)).beeFont(.caption) } }
                    Button("Изменить позицию") { edit(.cost(cost.id)) }
                }.frame(maxWidth: .infinity, alignment: .leading).beeCard() }
            }
            if page == .costs, let loan = d.loan { VStack(alignment:.leading,spacing:14) {
                Text("Ипотека / кредит").beeFont(.headline)
                Text("\(BeeFormat.money(loan.principal,currency:d.currency)) · \(loan.annualPercent)% · \(loan.months) месяцев")
                if let id = loan.contractID,let contract = db.financeData.contracts.first(where:{ $0.id == id }) { Text("Связан с реальным договором; выплаты уже включены в общий план.").beeFont(.caption); Button("Открыть договор и сценарии погашения") { model.openHistory(contract.accountID) } }
                else {
                    PlanningMoneyField(title:"Дополнительное досрочное погашение",amount:$prepay,currency:d.currency)
                    PlanningDateField(title:"Дата досрочного погашения",day:$prepayDate)
                    WrappingLayout(spacing: 12) { Button("Исходный график") { calculate(loan,mode:nil) }; Button("Уменьшить срок") { calculate(loan,mode:.reduceTerm) }; Button("Уменьшить платёж") { calculate(loan,mode:.reducePayment) } }
                    if !loanRows.isEmpty { let interest = (try? loanRows.reduce(Int64(0)) { try Money.add($0,$1.interest) }) ?? 0; Text("Проценты: " + BeeFormat.money(interest,currency:d.currency) + " · завершение " + (loanRows.last.map { CalendarDays.label($0.date,full:true) } ?? "—")); DisclosureGroup("График платежей (\(loanRows.count))") { ForEach(loanRows) { row in HStack { Text(CalendarDays.label(row.date)); Spacer(); Text("Тело " + BeeFormat.money(row.principal,currency:d.currency)); Text("Проценты " + BeeFormat.money(row.interest,currency:d.currency)); Text("Досрочно " + BeeFormat.money(row.extra,currency:d.currency)); Text("Остаток " + BeeFormat.money(row.remaining,currency:d.currency)) }.beeFont(.caption) } } }
                    if let loanError { Text(loanError).foregroundStyle(BeeStyle.negative) }
                    Text(loan.note + ". Сценарий не меняет реальный долг.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
                }
            }.beeCard() }
            if page == .costs, let business = d.business,let result = try? ProjectEngine.business(business) { VStack(alignment:.leading,spacing:12) {
                Text("Модель бизнеса").beeFont(.headline); projectNumber("Месячный результат",result.monthlyResult,currency:d.currency)
                Text(result.breakEvenRevenue.map { "Выручка для безубыточности: " + BeeFormat.money($0,currency:d.currency) } ?? "Безубыточность не рассчитана")
                Text(result.paybackMonths.map { "Возврат вложений: \($0) месяцев при постоянном результате" } ?? "Возврат вложений при текущем результате не достигается")
                Text("Выручка бизнеса и выплата участнику — разные потоки. " + business.taxBasis).beeFont(.caption).foregroundStyle(BeeStyle.muted)
            }.beeCard() }
            if page == .history { VStack(alignment:.leading,spacing:12) { Text("Версии принятого плана").beeFont(.headline); Button("Утвердить текущий план") { edit(.approve) }.buttonStyle(BeePrimaryStyle()); ForEach(d.versions) { version in Text("\(version.date.formatted(date:.abbreviated,time:.omitted)) · \(version.reason) · \(version.costs.count) позиций").beeFont(.caption) }; if d.versions.isEmpty { Text("Принятых версий пока нет. Изменение черновика не является утверждением.").beeFont(.caption) } }.beeCard() }
            if page == .payments {
                Button("Связать операцию / добавить оплату участника") { edit(.fact(nil)) }.buttonStyle(BeePrimaryStyle())
                ForEach((db.financeData.scheduledPayments ?? []).filter { p in d.costs.contains { $0.scheduledPaymentID == p.id } }) { p in Button(p.title) { model.sheet = SheetRoute(kind: .scheduledDetail, entityID: p.id) } }
                VStack(alignment:.leading,spacing:10) { Text("Факт проекта").beeFont(.headline); ForEach(d.facts) { fact in VStack(alignment: .leading, spacing: 8) { WrappingLayout(spacing: 12) { Text(CalendarDays.label(fact.date)); Text(fact.participantID.flatMap { id in d.participants.first { $0.id == id }?.name } ?? "Я"); Text(BeeFormat.money(fact.amount,currency:d.currency)) }; Text(fact.effectiveKind.title + " · " + (fact.confirmed ? "Подтверждено" : "Требует подтверждения")).beeFont(.caption); Button("Открыть факт") { edit(.fact(fact.id)) } } }; Text("Прямая оплата соучастника меняет факт проекта, сохраняя личные счета. Оплата не принимает работы.").beeFont(.caption).foregroundStyle(BeeStyle.muted) }.beeCard()
            }
        }
    } }
    private func projectNumber(_ title:String,_ amount:Int64,currency:String) -> some View { VStack(alignment:.leading,spacing:6) { Text(title).beeFont(.caption).foregroundStyle(BeeStyle.muted); Text(BeeFormat.money(amount,currency:currency)).beeFont(.title3).fixedSize(horizontal:false,vertical:true) } }
    private func calculate(_ loan:ProjectLoan,mode:PrepaymentMode?) { do { var extras = loan.prepayments; if let mode { extras.append(ProjectPrepayment(date:prepayDate,amount:prepay,mode:mode)) }; loanRows = try ProjectEngine.loanSchedule(loan,prepayments:extras); loanError = nil } catch { loanError = error.localizedDescription } }
}
struct ProjectDetailsEditor: View {
    @EnvironmentObject var model: AppModel; var id: UUID; var task: ProjectEditTask = .basic
    @State private var planningRevision: UInt64?
    @State private var entryID: UUID?
    @State private var project = Project(name:""); @State private var details = ProjectDetails(); @State private var loaded = false; @State private var original: Data?; @State private var hasDate = false; @State private var date = Day.today.adding(365)
    var body: some View { EditorFrame(title:task.title,isDirty:loaded && ((try? JSONEncoder().encode(details)) != original || project.name != model.db?.projects.first(where:{ $0.id == id })?.name || project.archived != model.db?.projects.first(where:{ $0.id == id })?.archived || hasDate != (details.dueOn != nil) || (hasDate && date != details.dueOn)),height:task == .basic ? 610 : 760,save:save) {
        if task == .basic {
        FormField(title:"Название") { TextField("Проект",text:$project.name).textFieldStyle(BeeTextFieldStyle()) }
        FinanceChoice(title:"Тип",value:$details.type,titleOf:{ $0.title }); FinanceChoice(title:"Стадия",value:$details.stage,titleOf:{ $0.title })
        CurrencyPicker(title:"Валюта проекта",selection:$details.currency).disabled(!details.facts.isEmpty || !details.versions.isEmpty)
        PlanningMoneyField(title:"Целевая сумма",amount:$details.target,currency:details.currency); PlanningMoneyField(title:"Неиспользованный резерв проекта",amount:$details.reserve,currency:details.currency)
        Toggle("Есть целевая дата",isOn:$hasDate); if hasDate { PlanningDateField(title:"Срок",day:$date) }
        Toggle("Проект в архиве",isOn:$project.archived)
        }
        if case .participant = task { DisclosureGroup("Участник и условия", isExpanded: .constant(true)) {
            ForEach(details.participants.indices.filter { details.participants[$0].id == entryID },id:\.self) { i in VStack(alignment:.leading,spacing:10) {
                TextField("Имя / организация",text:$details.participants[i].name).textFieldStyle(BeeTextFieldStyle())
                TextField("Роль",text:$details.participants[i].role).textFieldStyle(BeeTextFieldStyle())
                Toggle("Это мой профиль",isOn:$details.participants[i].isUser)
                PlanningMoneyField(title:"Обещанный вклад",amount:$details.participants[i].promised,currency:details.currency)
                Toggle("Вклад подтверждён",isOn:$details.participants[i].confirmed)
                TextField("Доля владения, %",text:Binding(get:{ details.participants[i].ownershipPercent ?? "" },set:{ details.participants[i].ownershipPercent = $0.isEmpty ? nil : $0 })).textFieldStyle(BeeTextFieldStyle())
                TextField("Доля распределяемого дохода, %",text:Binding(get:{ details.participants[i].incomePercent ?? "" },set:{ details.participants[i].incomePercent = $0.isEmpty ? nil : $0 })).textFieldStyle(BeeTextFieldStyle())
            }.padding(.vertical,10) }
        } }
        if case .cost = task { DisclosureGroup("Позиция и срок", isExpanded: .constant(true)) {
            ForEach(details.costs.indices.filter { details.costs[$0].id == entryID },id:\.self) { i in VStack(alignment:.leading,spacing:10) {
                TextField("Позиция сметы",text:$details.costs[i].title).textFieldStyle(BeeTextFieldStyle())
                TextField("Этап",text:$details.costs[i].stage)
                TextField("Подрядчик / основание договора",text:$details.costs[i].contractor).textFieldStyle(BeeTextFieldStyle()).textFieldStyle(BeeTextFieldStyle())
                PlanningMoneyField(title:"Сумма",amount:$details.costs[i].amount,currency:details.currency)
                PlanningDateField(title:"Срок оплаты",day:$details.costs[i].dueOn)
                Toggle("Есть принятый договор",isOn:$details.costs[i].contracted)
                Toggle("Результат работ принят отдельно от оплаты",isOn:$details.costs[i].accepted)
                participantPicker(selection:$details.costs[i].participantID)
                if let db = model.db { BeePicker("Связанный платёж",selection:$details.costs[i].scheduledPaymentID) { Text("Нет").tag(nil as UUID?); ForEach((db.financeData.scheduledPayments ?? []).filter { $0.currency == details.currency }) { Text($0.title).tag(Optional($0.id)) } } }
            }.padding(.vertical,10) }
        } }
        if case .fact = task { DisclosureGroup("Существующая операция или прямая оплата участника", isExpanded: .constant(true)) {
            ForEach(details.facts.indices.filter { details.facts[$0].id == entryID },id:\.self) { i in VStack(alignment:.leading,spacing:10) {
                PlanningDateField(title:"Дата",day:$details.facts[i].date); PlanningMoneyField(title:"Сумма",amount:$details.facts[i].amount,currency:details.currency)
                FinanceChoice(title:"Экономическая природа",value:Binding(get:{ details.facts[i].effectiveKind },set:{ details.facts[i].kind = $0; details.facts[i].income = [.revenue,.contribution,.distribution].contains($0) }),titleOf:{ $0.title }); participantPicker(selection:$details.facts[i].participantID)
                BeePicker("Позиция сметы",selection:$details.facts[i].costID) { Text("Без позиции").tag(nil as UUID?); ForEach(details.costs) { Text($0.title).tag(Optional($0.id)) } }
                if let db = model.db { BeePicker("Существующая операция",selection:$details.facts[i].operationID) { Text("Внешний факт участника").tag(nil as UUID?); ForEach(db.operations.filter { $0.kind == (details.facts[i].income ? .income : .expense) }) { Text("\($0.date.rawValue) · \($0.comment)").tag(Optional($0.id)) } } }
                if let db = model.db,details.facts[i].effectiveKind == .expense && details.facts[i].operationID == nil { BeePicker("Возмещение участнику — отдельный платёж",selection:$details.facts[i].reimbursementPaymentID) { Text("Нет обязательства возмещения").tag(nil as UUID?); ForEach((db.financeData.scheduledPayments ?? []).filter { $0.currency == details.currency }) { Text($0.title).tag(Optional($0.id)) } } }
                TextField("Основание факта",text:$details.facts[i].source).textFieldStyle(BeeTextFieldStyle()); Toggle("Факт подтверждён",isOn:$details.facts[i].confirmed)
            }.padding(.vertical,10) }
            Text("Связь с существующей операцией не создаёт второй расход. Оплата не подтверждает приёмку работ.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        } }
        if task == .loan {
            if details.loan == nil { Button("Добавить модель займа") { details.loan = ProjectLoan() } }
            else { ProjectLoanFields(loan:Binding(get:{ details.loan! },set:{ details.loan = $0 }),currency:details.currency) }
        }
        if task == .business {
            if details.business == nil { Button("Добавить бизнес-модель") { var b = BusinessModel(); b.currency = details.currency; details.business = b } }
            else { ProjectBusinessFields(business:Binding(get:{ details.business! },set:{ details.business = $0 }),currency:details.currency) }
        }
    }.onAppear {
        guard !loaded else { return }; planningRevision = model.db?.revision ?? 0
        if let saved = model.db?.projects.first(where:{ $0.id == id }) { project = saved; details = saved.details ?? details }
        date = details.dueOn ?? date; hasDate = details.dueOn != nil; original = try? JSONEncoder().encode(details)
        switch task {
        case let .cost(existing): if let existing { entryID = existing } else { let value = ProjectCost(title: "", amount: 0, dueOn: .today.adding(30)); entryID = value.id; details.costs.append(value) }
        case let .participant(existing): if let existing { entryID = existing } else { let value = ProjectParticipant(name: ""); entryID = value.id; details.participants.append(value) }
        case let .fact(existing): if let existing { entryID = existing } else { let value = ProjectFact(date: .today, amount: 0); entryID = value.id; details.facts.append(value) }
        case .loan: if details.loan == nil { details.loan = ProjectLoan() }
        case .business: if details.business == nil { var value = BusinessModel(); value.currency = details.currency; details.business = value }
        case .basic, .approve: break
        }
        loaded = true
    } }
    private func participantPicker(selection:Binding<UUID?>) -> some View { BeePicker("Участник / плательщик",selection:selection) { Text("Я / уточню").tag(nil as UUID?); ForEach(details.participants) { Text($0.name).tag(Optional($0.id)) } } }
    private func save() throws { details.dueOn = hasDate ? date : nil; details.migrated = false; project.details = details; try model.savePlanning(.project(project),expectedRevision:planningRevision) }
}
struct ProjectLoanFields: View {
    @EnvironmentObject var model: AppModel; @Binding var loan: ProjectLoan; var currency:String
    var body: some View { DisclosureGroup("Условия ипотеки / кредита", isExpanded: .constant(true)) {
        PlanningMoneyField(title:"Сумма займа",amount:$loan.principal,currency:currency); PlanningMoneyField(title:"Первоначальный взнос",amount:$loan.downPayment,currency:currency)
        TextField("Годовая ставка, %",text:$loan.annualPercent).textFieldStyle(BeeTextFieldStyle()); Stepper("Срок: \(loan.months) месяцев",value:$loan.months,in:1...600)
        PlanningDateField(title:"Первый платёж",day:$loan.firstPayment); Toggle("Дифференцированные платежи",isOn:$loan.differentiated)
        if let db = model.db { BeePicker("Связать реальный договор",selection:$loan.contractID) { Text("Пока только сценарий").tag(nil as UUID?); ForEach(db.financeData.contracts.filter { $0.kind.isDebt }) { contract in Text(db.accounts.first { $0.id == contract.accountID }?.name ?? contract.id.uuidString).tag(Optional(contract.id)) } } }
        ForEach(loan.prepayments.indices,id:\.self) { i in PlanningDateField(title:"Досрочный платёж \(i + 1)",day:$loan.prepayments[i].date); PlanningMoneyField(title:"Сумма",amount:$loan.prepayments[i].amount,currency:currency); FinanceChoice(title:"Результат",value:$loan.prepayments[i].mode,titleOf:{ $0 == .reduceTerm ? "Уменьшить срок" : $0 == .reducePayment ? "Уменьшить платёж" : "Ручной график" }) }
        Button("Добавить досрочное погашение") { loan.prepayments.append(ProjectPrepayment(date:loan.firstPayment,amount:0,mode:.reduceTerm)) }
        ForEach((loan.rateChanges ?? []).indices,id:\.self) { i in PlanningDateField(title:"Изменение ставки",day:Binding(get:{ loan.rateChanges![i].date },set:{ loan.rateChanges![i].date = $0 })); TextField("Новая годовая ставка, %",text:Binding(get:{ loan.rateChanges![i].annualPercent },set:{ loan.rateChanges![i].annualPercent = $0 })).textFieldStyle(BeeTextFieldStyle()) }
        Button("Добавить изменение ставки") { loan.rateChanges = (loan.rateChanges ?? []) + [ProjectLoanRate(date:loan.firstPayment,annualPercent:loan.annualPercent)] }
        DisclosureGroup("Ручной банковский график — имеет приоритет") {
            ForEach(loan.manual.indices,id:\.self) { i in PlanningDateField(title:"Дата выплаты",day:$loan.manual[i].date); PlanningMoneyField(title:"Тело",amount:$loan.manual[i].principal,currency:currency); PlanningMoneyField(title:"Проценты",amount:$loan.manual[i].interest,currency:currency); PlanningMoneyField(title:"Остаток после выплаты",amount:$loan.manual[i].remaining,currency:currency) }
            Button("Добавить строку ручного графика") { loan.manual.append(ProjectLoanRow(date:(try? FinanceMath.addingMonths(loan.firstPayment,loan.manual.count)) ?? loan.firstPayment,principal:0,interest:0,remaining:loan.principal)) }
            Button("Использовать модельный график") { loan.manual = [] }
        }
        TextField("Источник / условия графика",text:$loan.note).textFieldStyle(BeeTextFieldStyle())
        Text("Модель: равные месяцы; изменения внутри периода пропорциональны его дням. Договорный график имеет приоритет.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
    } }
}
struct ProjectBusinessFields: View {
    @Binding var business:BusinessModel; var currency:String
    var body: some View { DisclosureGroup("Месячная модель бизнеса", isExpanded: .constant(true)) {
        PlanningMoneyField(title:"Стартовые вложения",amount:$business.initial,currency:currency); PlanningMoneyField(title:"Прогноз выручки",amount:$business.revenue,currency:currency); PlanningMoneyField(title:"Постоянные затраты",amount:$business.fixed,currency:currency); PlanningMoneyField(title:"Переменные затраты",amount:$business.variable,currency:currency); PlanningMoneyField(title:"Ручной план налога",amount:$business.tax,currency:currency)
        Stepper("Горизонт бизнеса: \(business.horizonMonths ?? 60) месяцев",value:Binding(get:{ business.horizonMonths ?? 60 },set:{ business.horizonMonths = $0 }),in:1...600)
        TextField("Субъект, режим и основание налога",text:$business.taxBasis).textFieldStyle(BeeTextFieldStyle())
        Text("Автоматический расчёт бизнес-налогов не подключён. Выплаты участникам планируются отдельно от выручки.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
    } }
}

struct ProjectIncomeCalculator: View {
    var details:ProjectDetails; @State private var amount:Int64 = 0; @State private var result:[(UUID,Int64)] = []; @State private var error:String?
    var body: some View { DisclosureGroup("Расчёт распределяемого дохода участников") { VStack(alignment:.leading,spacing:12) {
        PlanningMoneyField(title:"Сумма для распределения",amount:$amount,currency:details.currency)
        Button("Рассчитать по подтверждённому правилу долей") { do { result = try ProjectEngine.splitIncome(amount,participants:details.participants); error = nil } catch { self.error = error.localizedDescription } }
        ForEach(result,id:\.0) { id,value in HStack { Text(details.participants.first { $0.id == id }?.name ?? "Участник"); Spacer(); Text(BeeFormat.money(value,currency:details.currency)) } }
        if !result.isEmpty { Text("Не распределено: " + BeeFormat.money(amount-result.reduce(Int64(0)) { $0+$1.1 },currency:details.currency)) }
        if let error { Text(error).foregroundStyle(BeeStyle.negative) }
        Text("Это расчёт, без движения денег. Фактическое получение дохода отмечается отдельно с участником и основанием выплаты.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
    }.padding(.top,12) }.beeCard() }
}
