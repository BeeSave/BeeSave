import SwiftUI
import BudgetCore
import BudgetPresentation

struct ProjectsView: View {
    @EnvironmentObject var model: AppModel; @State private var search = ""; @State private var archived = false; @State private var edit = false
    var body: some View { if let db = model.db { ScrollView { VStack(alignment:.leading,spacing:20) {
        if let id = model.planningProjectID,let project = db.projects.first(where:{ $0.id == id }) {
            SectionHeading(title:project.name) { Button("Все проекты",systemImage:"arrow.left") { model.planningProjectID = nil }; Button("Изменить план") { edit = true }.buttonStyle(BeePrimaryStyle()) }
            ProjectWorkspace(project:project)
        } else {
            SectionHeading(title:"Проекты") { Button("Новый проект",systemImage:"plus") { model.sheet = SheetRoute(kind:.project) }.buttonStyle(BeePrimaryStyle()) }
            HStack { TextField("Найти проект",text:$search).textFieldStyle(BeeTextFieldStyle()); Toggle("Показывать архив",isOn:$archived) }
            if db.projects.isEmpty { EmptyState(title:"Начните со значимой цели",detail:"Ипотека, ремонт, строительство или бизнес: оцените затраты, сроки и свой вклад.").beeCard() }
            LazyVGrid(columns:[GridItem(.adaptive(minimum:320,maximum:560))],spacing:18) {
                ForEach(db.projects.filter { (archived || !$0.archived) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { project in Button { model.planningProjectID = project.id } label: { VStack(alignment:.leading,spacing:12) {
                    let d = project.details ?? ProjectDetails()
                    Label(project.name,systemImage:d.type.icon).beeFont(.headline)
                    Text(d.type.title + " · " + d.stage.title).beeFont(.caption).foregroundStyle(BeeStyle.muted)
                    if let summary = try? ProjectEngine.summary(project:project,db:db) { if let loan = d.loan { Text("Сумма займа: " + BeeFormat.money(loan.principal,currency:d.currency)).beeFont(.title3) } else if let business = d.business { Text("Стартовые вложения: " + BeeFormat.money(business.initial,currency:d.currency)).beeFont(.title3) } else { Text("Прогноз: " + BeeFormat.money(summary.forecast,currency:d.currency)).beeFont(.title3) }; Text("Оплачено: " + BeeFormat.money(summary.paid,currency:d.currency)).beeFont(.caption) }
                    if let due = d.dueOn { Text(CalendarDays.label(due,full:true)).beeFont(.caption) }
                    if d.migrated { Text("Перенесённый проект · уточните план").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
                }.frame(maxWidth:.infinity,alignment:.leading).beeCard() }.buttonStyle(.plain) }
            }
        }
    }.padding(26) }.sheet(isPresented:$edit) { if let id = model.planningProjectID { ProjectDetailsEditor(id:id) } } } }
}
struct ProjectWorkspace: View {
    @EnvironmentObject var model: AppModel; var project: Project
    @State private var myFlow = false; @State private var reason = ""; @State private var prepay: Int64 = 0; @State private var prepayDate = Day.today.adding(30); @State private var loanRows: [ProjectLoanRow] = []; @State private var loanError: String?
    var body: some View { if let db = model.db { let d = project.details ?? ProjectDetails()
        VStack(alignment:.leading,spacing:20) {
            HStack { Label(d.type.title,systemImage:d.type.icon); Text(d.stage.title).foregroundStyle(BeeStyle.muted); Spacer(); if let date = d.dueOn { Text(CalendarDays.label(date,full:true)) } }
            if !project.description.isEmpty { Text(project.description) }
            if let summary = try? ProjectEngine.summary(project:project,db:db) {
                if d.loan == nil && d.business == nil { HStack(alignment:.top,spacing:24) { projectNumber("Оплачено",myFlow ? summary.userPaid : summary.paid,currency:d.currency); projectNumber("Прогноз всего проекта",summary.forecast,currency:d.currency); if d.target > 0 { projectNumber("Текущая цель",d.target,currency:d.currency) } }.beeCard() }
                Toggle("Мой денежный поток",isOn:$myFlow).toggleStyle(.switch)
                Text("Договоры: \(BeeFormat.money(summary.contractedRemaining,currency:d.currency)) · оставшиеся работы: \(BeeFormat.money(summary.uncommitted,currency:d.currency)) · резерв: \(BeeFormat.money(summary.reserve,currency:d.currency))").beeFont(.caption).foregroundStyle(BeeStyle.backgroundMuted)
            } else { Text("Не удалось оценить проект. Проверьте исторические валютные курсы.").foregroundStyle(BeeStyle.warning) }
            if !d.participants.isEmpty { ProjectIncomeCalculator(details:d)
            VStack(alignment:.leading,spacing:12) { Text("Участники").beeFont(.headline); ForEach(d.participants) { party in HStack { VStack(alignment:.leading) { Text(party.name + (party.isUser ? " · я" : "")); Text(party.role).beeFont(.caption).foregroundStyle(BeeStyle.muted) }; Spacer(); Text("Вклад: " + BeeFormat.money(party.promised,currency:d.currency)); Text(party.confirmed ? "Подтверждён" : "План").beeFont(.caption) } } }.beeCard() }
            if !d.costs.isEmpty { VStack(alignment:.leading,spacing:12) { Text("Смета и сроки").beeFont(.headline); ForEach(d.costs.filter { cost in !myFlow || cost.participantID == nil || d.participants.first(where:{ $0.id == cost.participantID })?.isUser == true }) { cost in HStack { VStack(alignment:.leading) { Text(cost.title); Text(cost.stage + " · " + (cost.contracted ? "Договор" : "Оценка")).beeFont(.caption).foregroundStyle(BeeStyle.muted) }; Spacer(); Text(CalendarDays.label(cost.dueOn)); Text(BeeFormat.money(cost.amount,currency:d.currency)); if let paid = try? ProjectEngine.paid(cost:cost,details:d,db:db) { Text("Факт: " + BeeFormat.money(paid,currency:d.currency)).beeFont(.caption) } } } }.beeCard() }
            if let loan = d.loan { VStack(alignment:.leading,spacing:14) {
                Text("Ипотека / кредит").beeFont(.headline)
                Text("\(BeeFormat.money(loan.principal,currency:d.currency)) · \(loan.annualPercent)% · \(loan.months) месяцев")
                if let id = loan.contractID,let contract = db.financeData.contracts.first(where:{ $0.id == id }) { Text("Связан с реальным договором; выплаты уже включены в общий план.").beeFont(.caption); Button("Открыть договор и сценарии погашения") { model.openHistory(contract.accountID) } }
                else {
                    PlanningMoneyField(title:"Дополнительное досрочное погашение",amount:$prepay,currency:d.currency)
                    PlanningDateField(title:"Дата досрочного погашения",day:$prepayDate)
                    HStack { Button("Исходный график") { calculate(loan,mode:nil) }; Button("Уменьшить срок") { calculate(loan,mode:.reduceTerm) }; Button("Уменьшить платёж") { calculate(loan,mode:.reducePayment) } }
                    if !loanRows.isEmpty { let interest = (try? loanRows.reduce(Int64(0)) { try Money.add($0,$1.interest) }) ?? 0; Text("Проценты: " + BeeFormat.money(interest,currency:d.currency) + " · завершение " + (loanRows.last.map { CalendarDays.label($0.date,full:true) } ?? "—")); DisclosureGroup("График платежей (\(loanRows.count))") { ForEach(loanRows) { row in HStack { Text(CalendarDays.label(row.date)); Spacer(); Text("Тело " + BeeFormat.money(row.principal,currency:d.currency)); Text("Проценты " + BeeFormat.money(row.interest,currency:d.currency)); Text("Досрочно " + BeeFormat.money(row.extra,currency:d.currency)); Text("Остаток " + BeeFormat.money(row.remaining,currency:d.currency)) }.beeFont(.caption) } } }
                    if let loanError { Text(loanError).foregroundStyle(BeeStyle.negative) }
                    Text(loan.note + ". Сценарий не меняет реальный долг.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
                }
            }.beeCard() }
            if let business = d.business,let result = try? ProjectEngine.business(business) { VStack(alignment:.leading,spacing:12) {
                Text("Модель бизнеса").beeFont(.headline); projectNumber("Месячный результат",result.monthlyResult,currency:d.currency)
                Text(result.breakEvenRevenue.map { "Выручка для безубыточности: " + BeeFormat.money($0,currency:d.currency) } ?? "Безубыточность не рассчитана")
                Text(result.paybackMonths.map { "Возврат вложений: \($0) месяцев при постоянном результате" } ?? "Возврат вложений при текущем результате не достигается")
                Text("Выручка бизнеса и выплата участнику — разные потоки. " + business.taxBasis).beeFont(.caption).foregroundStyle(BeeStyle.muted)
            }.beeCard() }
            VStack(alignment:.leading,spacing:12) { Text("Версии принятого плана").beeFont(.headline); TextField("Основание утверждения",text:$reason).textFieldStyle(BeeTextFieldStyle()); Button("Утвердить текущий план") { model.changePlanning(.approveProject(project.id,reason),reason:reason) }; ForEach(d.versions) { version in Text("\(version.date.formatted(date:.abbreviated,time:.omitted)) · \(version.reason) · \(version.costs.count) позиций").beeFont(.caption) } }.beeCard()
            VStack(alignment:.leading,spacing:10) { Text("Факты проекта").beeFont(.headline); ForEach(d.facts) { fact in HStack { Text(CalendarDays.label(fact.date)); Text(fact.participantID.flatMap { id in d.participants.first { $0.id == id }?.name } ?? "Я"); Spacer(); Text(BeeFormat.money(fact.amount,currency:d.currency)); Text(fact.effectiveKind.title + " · " + (fact.confirmed ? "Подтверждено" : "Требует подтверждения")).beeFont(.caption) } }; Text("Прямая оплата соучастника меняет факт проекта, сохраняя личные счета.").beeFont(.caption).foregroundStyle(BeeStyle.muted) }.beeCard()
        }
    } }
    private func projectNumber(_ title:String,_ amount:Int64,currency:String) -> some View { VStack(alignment:.leading,spacing:6) { Text(title).beeFont(.caption).foregroundStyle(BeeStyle.muted); Text(BeeFormat.money(amount,currency:currency)).beeFont(.title3).fixedSize(horizontal:false,vertical:true) } }
    private func calculate(_ loan:ProjectLoan,mode:PrepaymentMode?) { do { var extras = loan.prepayments; if let mode { extras.append(ProjectPrepayment(date:prepayDate,amount:prepay,mode:mode)) }; loanRows = try ProjectEngine.loanSchedule(loan,prepayments:extras); loanError = nil } catch { loanError = error.localizedDescription } }
}
struct ProjectDetailsEditor: View {
    @EnvironmentObject var model: AppModel; var id: UUID
    @State private var planningRevision: UInt64?
    @State private var project = Project(name:""); @State private var details = ProjectDetails(); @State private var loaded = false; @State private var original: Data?; @State private var hasDate = false; @State private var date = Day.today.adding(365)
    var body: some View { EditorFrame(title:"План проекта",isDirty:loaded && ((try? JSONEncoder().encode(details)) != original || project.name != model.db?.projects.first(where:{ $0.id == id })?.name || project.archived != model.db?.projects.first(where:{ $0.id == id })?.archived || hasDate != (details.dueOn != nil) || (hasDate && date != details.dueOn)),height:800,save:save) {
        FormField(title:"Название") { TextField("Проект",text:$project.name).textFieldStyle(BeeTextFieldStyle()) }
        FinanceChoice(title:"Тип",value:$details.type,titleOf:{ $0.title }); FinanceChoice(title:"Стадия",value:$details.stage,titleOf:{ $0.title })
        CurrencyPicker(title:"Валюта проекта",selection:$details.currency).disabled(!details.facts.isEmpty || !details.versions.isEmpty)
        PlanningMoneyField(title:"Целевая сумма",amount:$details.target,currency:details.currency); PlanningMoneyField(title:"Неиспользованный резерв проекта",amount:$details.reserve,currency:details.currency)
        Toggle("Есть целевая дата",isOn:$hasDate); if hasDate { PlanningDateField(title:"Срок",day:$date) }
        DisclosureGroup("Участники и условия") {
            ForEach(details.participants.indices,id:\.self) { i in VStack(alignment:.leading,spacing:10) {
                TextField("Имя / организация",text:$details.participants[i].name).textFieldStyle(BeeTextFieldStyle())
                TextField("Роль",text:$details.participants[i].role).textFieldStyle(BeeTextFieldStyle())
                Toggle("Это мой профиль",isOn:$details.participants[i].isUser)
                PlanningMoneyField(title:"Обещанный вклад",amount:$details.participants[i].promised,currency:details.currency)
                Toggle("Вклад подтверждён",isOn:$details.participants[i].confirmed)
                TextField("Доля владения, %",text:Binding(get:{ details.participants[i].ownershipPercent ?? "" },set:{ details.participants[i].ownershipPercent = $0.isEmpty ? nil : $0 })).textFieldStyle(BeeTextFieldStyle())
                TextField("Доля распределяемого дохода, %",text:Binding(get:{ details.participants[i].incomePercent ?? "" },set:{ details.participants[i].incomePercent = $0.isEmpty ? nil : $0 })).textFieldStyle(BeeTextFieldStyle())
            }.padding(.vertical,10) }
            Button("Добавить соучастника") { details.participants.append(ProjectParticipant(name:"")) }
        }
        DisclosureGroup("Этапы и смета") {
            ForEach(details.costs.indices,id:\.self) { i in VStack(alignment:.leading,spacing:10) {
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
            Button("Добавить позицию") { details.costs.append(ProjectCost(title:"",amount:0,dueOn:.today.adding(30))) }
        }
        DisclosureGroup("Факт: свои операции и прямые оплаты участника") {
            ForEach(details.facts.indices,id:\.self) { i in VStack(alignment:.leading,spacing:10) {
                PlanningDateField(title:"Дата",day:$details.facts[i].date); PlanningMoneyField(title:"Сумма",amount:$details.facts[i].amount,currency:details.currency)
                FinanceChoice(title:"Экономическая природа",value:Binding(get:{ details.facts[i].effectiveKind },set:{ details.facts[i].kind = $0; details.facts[i].income = [.revenue,.contribution,.distribution].contains($0) }),titleOf:{ $0.title }); participantPicker(selection:$details.facts[i].participantID)
                BeePicker("Позиция сметы",selection:$details.facts[i].costID) { Text("Без позиции").tag(nil as UUID?); ForEach(details.costs) { Text($0.title).tag(Optional($0.id)) } }
                if let db = model.db { BeePicker("Существующая операция",selection:$details.facts[i].operationID) { Text("Внешний факт участника").tag(nil as UUID?); ForEach(db.operations.filter { $0.kind == (details.facts[i].income ? .income : .expense) }) { Text("\($0.date) · \($0.comment)").tag(Optional($0.id)) } } }
                if let db = model.db,details.facts[i].effectiveKind == .expense && details.facts[i].operationID == nil { BeePicker("Возмещение участнику — отдельный платёж",selection:$details.facts[i].reimbursementPaymentID) { Text("Нет обязательства возмещения").tag(nil as UUID?); ForEach((db.financeData.scheduledPayments ?? []).filter { $0.currency == details.currency }) { Text($0.title).tag(Optional($0.id)) } } }
                TextField("Основание факта",text:$details.facts[i].source).textFieldStyle(BeeTextFieldStyle()); Toggle("Факт подтверждён",isOn:$details.facts[i].confirmed)
            }.padding(.vertical,10) }
            Button("Добавить факт") { details.facts.append(ProjectFact(date:.today,amount:0)) }
        }
        if details.type == .mortgage {
            if details.loan == nil { Button("Добавить модель займа") { details.loan = ProjectLoan() } }
            else { ProjectLoanFields(loan:Binding(get:{ details.loan! },set:{ details.loan = $0 }),currency:details.currency) }
        }
        if details.type == .business {
            if details.business == nil { Button("Добавить бизнес-модель") { var b = BusinessModel(); b.currency = details.currency; details.business = b } }
            else { ProjectBusinessFields(business:Binding(get:{ details.business! },set:{ details.business = $0 }),currency:details.currency) }
        }
        Toggle("Проект в архиве",isOn:$project.archived)
    }.onAppear { guard !loaded else { return }; planningRevision = model.db?.revision ?? 0; if let saved = model.db?.projects.first(where:{ $0.id == id }) { project = saved; details = saved.details ?? details }; date = details.dueOn ?? date; hasDate = details.dueOn != nil; original = try? JSONEncoder().encode(details); loaded = true } }
    private func participantPicker(selection:Binding<UUID?>) -> some View { BeePicker("Участник / плательщик",selection:selection) { Text("Я / уточню").tag(nil as UUID?); ForEach(details.participants) { Text($0.name).tag(Optional($0.id)) } } }
    private func save() throws { details.dueOn = hasDate ? date : nil; details.migrated = false; project.details = details; try model.savePlanning(.project(project),expectedRevision:planningRevision) }
}
struct ProjectLoanFields: View {
    @EnvironmentObject var model: AppModel; @Binding var loan: ProjectLoan; var currency:String
    var body: some View { DisclosureGroup("Условия ипотеки / кредита") {
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
    var body: some View { DisclosureGroup("Месячная модель бизнеса") {
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
