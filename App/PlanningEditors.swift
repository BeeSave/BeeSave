import SwiftUI
import BudgetCore
import BudgetPresentation

struct PlanningMoneyField: View {
    var title: String; @Binding var amount: Int64; var currency: String
    @State private var text = ""; @State private var loaded = false
    var body: some View { FormField(title:title + " · " + currency) {
        TextField("0",text:$text).textFieldStyle(BeeTextFieldStyle())
            .onAppear { if !loaded { text = Money.string(amount,currency:currency); loaded = true } }
            .onChange(of:text) { _,v in amount = (try? Money.parse(v,currency:currency)) ?? -1 }
            .onChange(of:currency) { old,v in if loaded { if (try? Money.parse(text,currency:old)) == amount { amount = (try? Money.parse(text,currency:v)) ?? -1 } else if amount >= 0 { text = Money.string(amount,currency:v) } } }
            .onChange(of:amount) { _,v in if loaded && v >= 0 && (try? Money.parse(text,currency:currency)) != v { text = Money.string(v,currency:currency) } }
        if amount < 0 { Text("Введите корректную неотрицательную сумму").beeFont(.caption).foregroundStyle(BeeStyle.negative) }
    } }
}
struct PlanningDateField: View {
    var title: String; @Binding var day: Day
    var body: some View { DatePicker(title,selection:Binding(get:{ day.date },set:{ day = Day.utc($0) }),displayedComponents:.date).environment(\.timeZone,TimeZone(secondsFromGMT:0)!) }
}
struct PlanFlowEditor: View {
    @EnvironmentObject var model: AppModel; var id: UUID?; var initialPurpose: PlanPurpose? = nil
    @State private var flow = PlanFlow(title:"",purpose:.payment,amount:0,currency:"RUB",start:.today)
    @State private var amount: Int64 = 0; @State private var unknown = false; @State private var hasEnd = false; @State private var end = Day.today.adding(365)
    @State private var loaded = false; @State private var original: Data?; @State private var planningRevision: UInt64?
    @State private var exception = PlanException(anchor:.today); @State private var exceptionAmount: Int64 = 0; @State private var exceptionOverride = false
    private var dirty: Bool { loaded && ((try? JSONEncoder().encode(flow)) != original || amount != (flow.amount ?? 0) || unknown != (flow.amount == nil) || hasEnd != (flow.end != nil) || (hasEnd && end != flow.end)) }
    var body: some View {
        EditorFrame(title:id == nil ? "Добавить в регулярный план" : "Регулярный план",isDirty:dirty,height:740,save:save) {
            FormField(title:"Название") { TextField("ЖКХ, зарплата, жизнь…",text:$flow.title).textFieldStyle(BeeTextFieldStyle()) }
            FinanceChoice(title:"Назначение",value:$flow.purpose,titleOf:{ $0.title })
            CurrencyPicker(title:"Валюта",selection:$flow.currency)
            Toggle("Сумма требует уточнения",isOn:$unknown)
            if !unknown { PlanningMoneyField(title:flow.purpose == .living ? "Лимит на период" : "Сумма",amount:$amount,currency:flow.currency) }
            FinanceChoice(title:"Повторение",value:$flow.frequency,titleOf:{ $0.title })
            PlanningDateField(title:"Первая дата",day:$flow.start)
            Toggle("Есть дата окончания",isOn:$hasEnd); if hasEnd { PlanningDateField(title:"Последняя дата",day:$end) }
            if flow.frequency == .manual {
                ForEach(flow.dates.indices,id:\.self) { i in PlanningDateField(title:"Дата \(i + 1)",day:$flow.dates[i]) }
                Button("Добавить дату") { flow.dates.append((flow.dates.last ?? flow.start).adding(1)) }
            }
            FinanceChoice(title:"Достоверность",value:$flow.certainty,titleOf:{ $0.title })
            Toggle("Входит в мой личный денежный план",isOn:Binding(get:{ flow.personalImpact != false },set:{ flow.personalImpact = $0 }))
            DisclosureGroup("Счёт, категория и проект") {
            if let db = model.db {
                FormField(title:"Предполагаемый счёт") { BeePicker("Счёт",selection:$flow.accountID) { Text("При оплате").tag(nil as UUID?); ForEach(db.accounts.filter { !$0.archived && $0.kind == .ordinary && $0.currency == flow.currency }) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden() }
                FormField(title:"Категория") { BeePicker("Категория",selection:$flow.categoryID) { Text("Без категории").tag(nil as UUID?); ForEach(db.categories.filter { !$0.archived && $0.kind == (flow.purpose == .income ? .income : .expense) }) { Text(db.categoryPath($0.id)).tag(Optional($0.id)) } }.labelsHidden() }
                if flow.purpose != .income && flow.frequency == .monthly { BeePicker("Входит в общий лимит жизни",selection:$flow.parentFlowID) { Text("Отдельная сумма").tag(nil as UUID?); ForEach(db.planningData.flows.filter { $0.id != flow.id && $0.purpose == .living && $0.frequency == .monthly && $0.parentFlowID == nil && $0.currency == flow.currency }) { Text($0.title).tag(Optional($0.id)) } } }
                FormField(title:"Проект") { BeePicker("Проект",selection:$flow.projectID) { Text("Без проекта").tag(nil as UUID?); ForEach(db.projects.filter { !$0.archived }) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden() }
            }
            }
            FormField(title:"Основание / комментарий") { TextField("Условия плана",text:$flow.comment).textFieldStyle(BeeTextFieldStyle()) }
            Toggle("Учитывать будущие вхождения",isOn:$flow.enabled)
            if id != nil {
                Divider(); Text("Исключение для одного периода").beeFont(.headline)
                PlanningDateField(title:"Исходная дата вхождения",day:$exception.anchor)
                PlanningDateField(title:"Перенести на",day:Binding(get:{ exception.date ?? exception.anchor },set:{ exception.date = $0 }))
                Toggle("Изменить сумму вхождения",isOn:$exceptionOverride)
                if exceptionOverride { PlanningMoneyField(title:"Сумма вхождения",amount:$exceptionAmount,currency:flow.currency) }
                Toggle("Отменить это вхождение",isOn:$exception.cancelled)
                if flow.purpose == .living { Toggle("Период закрыт, дальнейших трат не будет",isOn:$exception.closed) }
                Button("Добавить / изменить исключение") { exception.amount = exceptionOverride ? exceptionAmount : nil; flow.exceptions.removeAll { $0.anchor == exception.anchor }; flow.exceptions.append(exception) }
                ForEach(flow.exceptions,id:\.anchor) { e in Text("\(e.anchor.rawValue): \(e.cancelled ? "отменено" : e.closed ? "период закрыт" : "исключение")").beeFont(.caption) }
                Text("Для изменения всей серии сохраните новые условия. Уже учтённые факты сохраняются.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
            }
        }.onAppear { guard !loaded else { return }; planningRevision = model.db?.revision ?? 0; if let saved = model.db?.planningData.flows.first(where:{ $0.id == id }) { flow = saved } else { flow.currency = model.db?.settings.baseCurrency ?? "RUB"; if let initialPurpose { flow.purpose = initialPurpose } }; amount = flow.amount ?? 0; unknown = flow.amount == nil; hasEnd = flow.end != nil; end = flow.end ?? end; original = try? JSONEncoder().encode(flow); loaded = true }
        .onChange(of:flow.purpose) { _,_ in if let categoryID = flow.categoryID,model.db?.categories.first(where:{ $0.id == categoryID })?.kind != (flow.purpose == .income ? .income : .expense) { flow.categoryID = nil }; if flow.purpose == .income { flow.parentFlowID = nil } }
        .onChange(of:flow.frequency) { _,_ in if flow.frequency != .monthly { flow.parentFlowID = nil } }
        .onChange(of:flow.currency) { _,v in if let accountID = flow.accountID,model.db?.accounts.first(where:{ $0.id == accountID })?.currency != v { flow.accountID = nil } }
    }
    private func save() throws { flow.amount = unknown ? nil : amount; flow.end = hasEnd ? end : nil; try model.savePlanning(.flow(flow),expectedRevision:planningRevision) }
}
struct SavingsGoalEditor: View {
    @EnvironmentObject var model: AppModel; var id: UUID?
    @State private var goal = SavingsGoal(title:"",target:0,currency:"RUB",dueOn:.today.adding(365)); @State private var loaded = false; @State private var original: Data?; @State private var planningRevision: UInt64?
    var body: some View { EditorFrame(title:"Цель накопления",isDirty:loaded && (try? JSONEncoder().encode(goal)) != original,height:650,save:{ try model.savePlanning(.goal(goal),expectedRevision:planningRevision) }) {
        FormField(title:"Цель") { TextField("Подушка, дом, автомобиль…",text:$goal.title).textFieldStyle(BeeTextFieldStyle()) }
        CurrencyPicker(title:"Валюта",selection:$goal.currency)
        PlanningMoneyField(title:"Нужно накопить",amount:$goal.target,currency:goal.currency)
        PlanningMoneyField(title:"Уже выделено",amount:$goal.allocated,currency:goal.currency)
        PlanningMoneyField(title:"Ежемесячно выделять",amount:$goal.monthly,currency:goal.currency)
        PlanningDateField(title:"Желаемая дата",day:$goal.dueOn)
        if let db = model.db { FormField(title:"Источник выделенных средств") { BeePicker("Счёт",selection:$goal.accountID) { Text("Уточню позднее").tag(nil as UUID?); ForEach(db.accounts.filter { !$0.kind.isDebt && $0.currency == goal.currency }) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden() } }
        if let result = try? PlanningEngine.savings(goal) { Text("Требуется в месяц: " + BeeFormat.money(result.requiredMonthly,currency:goal.currency)); Text(result.achievableOn.map { "При выбранном темпе: " + CalendarDays.label($0,full:true) } ?? "Задайте темп пополнения") }
        Text("Выделение на цель не списывает деньги. Реальный перевод между своими счетами учитывается отдельно.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
    }.onAppear { guard !loaded else { return }; planningRevision = model.db?.revision ?? 0; if let saved = model.db?.planningData.goals.first(where:{ $0.id == id }) { goal = saved }; original = try? JSONEncoder().encode(goal); loaded = true } }
}
struct PlanFactEditor: View {
    @EnvironmentObject var model: AppModel; var flowID: UUID?
    @State private var planningRevision: UInt64?
    @State private var occurrenceID = ""; @State private var accountID: UUID?; @State private var operationID: UUID?; @State private var amount: Int64 = 0; @State private var date = Day.today
    private var flow: PlanFlow? { model.db?.planningData.flows.first { $0.id == flowID } }
    private var occurrences: [PlannedOccurrence] { guard let flow,let db = model.db else { return [] }; return (try? PlanningEngine.occurrences(flow:flow,db:db,from:.today.adding(-365),through:.today.adding(365))) ?? [] }
    var body: some View { EditorFrame(title:"Подтвердить факт",isDirty:amount > 0,height:620,save:save) {
        if let flow,let db = model.db {
            Text(flow.title).beeFont(.headline)
            BeePicker("Вхождение",selection:$occurrenceID) { Text("Выберите период").tag(""); ForEach(occurrences) { Text(CalendarDays.label($0.anchor,full:true)).tag($0.id) } }
            PlanningMoneyField(title:"Учесть сумму",amount:$amount,currency:flow.currency)
            BeePicker("Связать существующую операцию",selection:$operationID) { Text("Создать новую").tag(nil as UUID?); ForEach(db.operations.filter { $0.kind == (flow.purpose == .income ? .income : .expense) && (try? db.account($0.accountID).currency) == flow.currency }) { Text("\($0.date.rawValue) · \(BeeFormat.money($0.amount,currency:flow.currency)) · \($0.comment)").tag(Optional($0.id)) } }
            if operationID == nil { BeePicker("Счёт",selection:$accountID) { Text("Выберите").tag(nil as UUID?); ForEach(db.accounts.filter { !$0.archived && $0.kind == .ordinary && $0.currency == flow.currency }) { Text($0.name).tag(Optional($0.id)) } }; PlanningDateField(title:"Дата факта",day:$date) }
            Text("План не подтверждается автоматически. Связанный факт учитывается один раз; возможна частичная оплата.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        }
    }.onAppear { if planningRevision == nil { planningRevision = model.db?.revision ?? 0 } }.onChange(of:occurrenceID) { _,id in amount = occurrences.first { $0.id == id }?.remaining ?? 0 }
    }
    private func save() throws {
        guard let flow,let db = model.db,occurrences.contains(where:{ $0.id == occurrenceID }),amount > 0 else { throw BudgetError.invalid("Выберите вхождение и положительную сумму.") }
        if let operationID { try model.savePlanning(.allocate(PlanAllocation(occurrenceID:occurrenceID,operationID:operationID,sourceAmount:amount,amount:amount)),expectedRevision:planningRevision) }
        else {
            guard let accountID else { throw BudgetError.invalid("Выберите счёт.") }
            var op = Operation(kind:flow.purpose == .income ? .income : .expense,date:date,accountID:accountID,amount:amount)
            op.categoryID = flow.categoryID ?? db.categories.first { $0.kind == op.kind && $0.system }?.id; op.projectID = flow.projectID; op.comment = flow.title
            try model.savePlanning(.executeFlow(op,PlanAllocation(occurrenceID:occurrenceID,operationID:op.id,sourceAmount:amount,amount:amount)),expectedRevision:planningRevision)
        }
    }
}
struct PlanningEventSettingsEditor: View {
    @EnvironmentObject var model: AppModel; @State private var settings = PlanningEventSettings(); @State private var loaded = false; @State private var planningRevision: UInt64?
    var body: some View { EditorFrame(title:"Полезные события",isDirty:loaded,height:600,save:{ try model.savePlanning(.settings(settings),expectedRevision:planningRevision) }) {
        ForEach([("payment","Обязательные платежи"),("deposit","Завершение вкладов"),("deficit","Риск нехватки денег"),("project","Сроки проектов"),("tax","Налоговые сроки")],id:\.0) { type,title in Toggle(title,isOn:Binding(get:{ settings.enabledTypes.contains(type) },set:{ v in settings.enabledTypes.removeAll { $0 == type }; if v { settings.enabledTypes.append(type) } })); Stepper("Важность: \(settings.priorityOverrides?[type] ?? (type == "deficit" ? 0 : type == "deposit" ? 2 : 1)) · 0 — самая высокая",value:Binding(get:{ settings.priorityOverrides?[type] ?? (type == "deficit" ? 0 : type == "deposit" ? 2 : 1) },set:{ v in if settings.priorityOverrides == nil { settings.priorityOverrides = [:] }; settings.priorityOverrides?[type] = v }),in:0...3) }
        Stepper("Платежи: за \(settings.paymentDays) дней",value:$settings.paymentDays,in:0...365)
        Stepper("Вклады: за \(settings.depositDays) дней",value:$settings.depositDays,in:0...365)
        Stepper("Дефицит: \(settings.deficitDays) дней",value:$settings.deficitDays,in:0...365)
        Text("Настройки управляют подсказками. Неоплаченные обязательства и нехватка денег остаются в плане и календаре.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        Button("Вернуть скрытые события") { settings.hiddenKeys = []; settings.sourceExclusions = []; settings.snoozed = [:] }
    }.onAppear { if !loaded { planningRevision = model.db?.revision ?? 0; settings = model.db?.planningData.eventSettings ?? settings; loaded = true } } }
}
