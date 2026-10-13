import SwiftUI
import BudgetCore
import BudgetPresentation

struct TaxProfileEditor: View {
    @EnvironmentObject var model: AppModel; var id: UUID?
    @State private var planningRevision: UInt64?
    @State private var profile = TaxProfile(); @State private var result: TaxCalculation?; @State private var loaded = false; @State private var original: Data?; @State private var hasDate = false; @State private var date = Day.today.adding(30)
    var body: some View { EditorFrame(title:"Налоги и вычеты",isDirty:loaded && ((try? JSONEncoder().encode(profile)) != original || hasDate != (profile.expectedOn != nil) || (hasDate && date != profile.expectedOn)),height:780,save:save) {
        FormField(title:"Название расчёта") { TextField("НДФЛ и вычеты",text:$profile.title).textFieldStyle(BeeTextFieldStyle()) }
        BeePicker("Страна",selection:$profile.country) { Text("Россия").tag("RU"); Text("Другая страна — модуль не подключён").tag("OTHER") }
        BeePicker("Налоговый год",selection:$profile.year) { Text("2025").tag(2025); Text("2026").tag(2026); Text("2027 — пока вне покрытия").tag(2027) }
        Toggle("Налоговый резидент РФ",isOn:$profile.resident)
        PlanningMoneyField(title:"Трудовой доход до удержаний за весь год",amount:$profile.grossEmployment,currency:"RUB")
        Toggle("Указан чистый доход после удержания",isOn:$profile.incomeIsNet)
        PlanningMoneyField(title:"Удержанный / уплаченный НДФЛ",amount:$profile.withheld,currency:"RUB")
        PlanningMoneyField(title:"Другие подтверждённые вычеты из базы",amount:$profile.verifiedOtherDeductions,currency:"RUB")
        Toggle("Есть другие виды доходов / особые ставки",isOn:$profile.unsupportedIncome)
        Text("Укажите ещё не заявленные допустимые расходы. Уже использованные суммы уменьшают оставшийся лимит; удержанный налог — фактически уплаченная сумма за год.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        DisclosureGroup("Жильё и ипотечные проценты") {
            Toggle("Подтверждены условия вычета на жильё",isOn:$profile.housingEligible)
            Toggle("Право и договор относятся к правилам после 2014",isOn:$profile.housingAfter2014)
            PlanningMoneyField(title:"Допустимые расходы на жильё",amount:$profile.housingCost,currency:"RUB")
            PlanningMoneyField(title:"Уже использована база жилищного вычета",amount:$profile.housingUsed,currency:"RUB")
            Toggle("Подтверждены условия целевого ипотечного займа",isOn:$profile.interestEligible)
            PlanningMoneyField(title:"Допустимые фактически уплаченные проценты",amount:$profile.interestCost,currency:"RUB")
            PlanningMoneyField(title:"Уже использована база вычета процентов",amount:$profile.interestUsed,currency:"RUB")
        }
        DisclosureGroup("Лечение и обучение") {
            Toggle("Условия и документы социального вычета подтверждены",isOn:$profile.socialEligible)
            PlanningMoneyField(title:"Обычное лечение / лекарства",amount:$profile.treatment,currency:"RUB")
            PlanningMoneyField(title:"Собственное обучение",amount:$profile.education,currency:"RUB")
            PlanningMoneyField(title:"Другие расходы в общем социальном лимите",amount:$profile.otherSocial,currency:"RUB")
            PlanningMoneyField(title:"Уже использован общий социальный лимит",amount:$profile.socialUsed,currency:"RUB")
            PlanningMoneyField(title:"Подтверждённое дорогостоящее лечение",amount:$profile.expensiveTreatment,currency:"RUB")
            ForEach(profile.childEducation.indices,id:\.self) { index in VStack(alignment:.leading) { Text("Обучение ребёнка \(index + 1)"); PlanningMoneyField(title:"Допустимые расходы",amount:$profile.childEducation[index].eligibleCost,currency:"RUB"); PlanningMoneyField(title:"Заявлено другим родителем",amount:$profile.childEducation[index].claimedByOtherParent,currency:"RUB") } }
            Button("Добавить обучение ребёнка") { profile.childEducation.append(ChildEducationCost(eligibleCost:0)) }
        }
        FinanceChoice(title:"Стадия возмещения",value:$profile.stage,titleOf:{ $0.title })
        Toggle("Задать предполагаемый срок выплаты / возврата",isOn:$hasDate); if hasDate { PlanningDateField(title:"Предполагаемая дата",day:$date) }
        if let db = model.db { BeePicker("Связать факт возврата",selection:$profile.refundOperationID) { Text("Возврат ещё не поступил").tag(nil as UUID?); ForEach(db.operations.filter { $0.kind == .income }) { Text("\($0.date) · \($0.comment)").tag(Optional($0.id)) } } }
        Button("Рассчитать") { calculate() }.buttonStyle(BeePrimaryStyle())
        if let result {
            if result.complete { Text("НДФЛ после вычетов: " + BeeFormat.money(result.tax ?? 0,currency:"RUB")).beeFont(.headline); Text("К доплате: " + BeeFormat.money(result.payable ?? 0,currency:"RUB")); Text("Возможный возврат: " + BeeFormat.money(result.refund ?? 0,currency:"RUB")).foregroundStyle(BeeStyle.positive); Text("База вычетов: социальный \(BeeFormat.money(result.socialBase,currency:"RUB")), жильё \(BeeFormat.money(result.housingBase,currency:"RUB")), проценты \(BeeFormat.money(result.interestBase,currency:"RUB"))").beeFont(.caption) }
            else { Text("Расчёт неполный: " + result.missing.joined(separator:"; ")).foregroundStyle(BeeStyle.warning) }
            if let rules = result.rules { Text("\(rules.version) · проверка источников \(rules.checkedOn)").beeFont(.caption).foregroundStyle(BeeStyle.muted); ForEach(rules.sources,id:\.self) { url in if let url = URL(string:url) { Link("Источник ФНС",destination:url).beeFont(.caption) } } }
        }
        if let db = model.db {
            let saved = db.planningData.taxResults.filter { $0.profileID == profile.id }.sorted { $0.date > $1.date }
            if !saved.isEmpty { DisclosureGroup("Сохранённые расчёты (\(saved.count))") {
                ForEach(saved) { previous in VStack(alignment:.leading,spacing:6) {
                    Text(previous.date.formatted(date:.abbreviated,time:.shortened) + " · " + (previous.rules?.version ?? "Вне покрытия")).beeFont(.caption)
                    if previous.complete { Text("Налог: " + BeeFormat.money(previous.tax ?? 0,currency:"RUB") + " · возврат: " + BeeFormat.money(previous.refund ?? 0,currency:"RUB")) }
                    else { Text(previous.missing.joined(separator:"; ")).foregroundStyle(BeeStyle.warning) }
                    if let input = previous.input { Text("Доход до удержаний: " + BeeFormat.money(input.grossEmployment,currency:"RUB") + " · удержано: " + BeeFormat.money(input.withheld,currency:"RUB")).beeFont(.caption) }
                    if let current = result,current.complete,previous.complete { Text("Изменение налога: " + BeeFormat.money((current.tax ?? 0) - (previous.tax ?? 0),currency:"RUB")).beeFont(.caption) }
                }.padding(.vertical,6) }
            } }
        }
        Text("Вычет уменьшает налоговую базу. Возможный возврат не считается гарантированными деньгами и не включает налоги бизнеса.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
    }.onAppear { guard !loaded else { return }; planningRevision = model.db?.revision ?? 0; if let saved = model.db?.planningData.taxes.first(where:{ $0.id == id }) { profile = saved }; original = try? JSONEncoder().encode(profile); date = profile.expectedOn ?? date; hasDate = profile.expectedOn != nil; loaded = true; calculate() } }
    private func calculate() { do { result = try CountryModules.calculate(profile,revision:model.db?.revision ?? 0) } catch { model.error = error.localizedDescription } }
    private func save() throws { profile.expectedOn = hasDate ? date : nil; if profile.refundOperationID != nil { profile.stage = .received }; try model.savePlanning(.tax(profile),expectedRevision:planningRevision) }
}
